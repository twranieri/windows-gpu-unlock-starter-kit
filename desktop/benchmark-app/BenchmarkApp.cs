// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("RTX Tensor Benchmark")]
[assembly: System.Reflection.AssemblyProduct("RTX Tensor Benchmark")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]

internal sealed class BenchmarkApp : Form
{
    private sealed class Gpu
    {
        public string Pci, Uuid, Name;
        public override string ToString() { return Name + "  (" + Pci + ")"; }
    }

    private readonly string package = AppDomain.CurrentDomain.BaseDirectory;
    private readonly string results = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RTX Tensor Benchmark", "Results");
    private readonly ComboBox cards = new ComboBox();
    private readonly Button before = new Button { Text = "Run before", AutoSize = true };
    private readonly Button after = new Button { Text = "Run after", AutoSize = true };
    private readonly Button retry = new Button { Text = "Retry GPU detection", AutoSize = true };
    private readonly Button open = new Button { Text = "Open results", AutoSize = true };
    private readonly Label status = new Label { AutoSize = true };
    private readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Top, Height = 7 };
    private readonly TextBox activity = new TextBox {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false,
        Dock = DockStyle.Fill, Font = new Font("Consolas", 10), BackColor = Color.White
    };
    private bool busy;

    [STAThread]
    private static void Main()
    {
        bool first;
        using (var instance = new Mutex(true, @"Local\RTXTensors.BenchmarkApp.1", out first))
        {
            if (!first)
            {
                MessageBox.Show("The benchmark is already open. Switch to its existing window.", "RTX Tensor Benchmark");
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new BenchmarkApp());
        }
    }

    private BenchmarkApp()
    {
        Text = "RTX Tensor Benchmark";
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Font;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(770, 510);
        MinimumSize = new Size(680, 470);
        var layout = new TableLayoutPanel {
            Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 1, RowCount = 8,
            BackColor = Color.FromArgb(246, 248, 251)
        };
        for (int row = 0; row < 7; row++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(layout);
        layout.Controls.Add(new Label {
            Text = "RTX Tensor Benchmark", AutoSize = true, Font = new Font("Segoe UI", 21, FontStyle.Bold)
        });
        layout.Controls.Add(new Label {
            Text = "Save a before and after measurement on the same GPU.",
            AutoSize = true, Margin = new Padding(3, 3, 3, 16)
        });
        layout.Controls.Add(new Label { Text = "NVIDIA GPU", AutoSize = true });
        cards.DropDownStyle = ComboBoxStyle.DropDownList;
        cards.Dock = DockStyle.Top;
        cards.AccessibleName = "NVIDIA GPU";
        layout.Controls.Add(cards);
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 8, 0, 4) };
        buttons.Controls.AddRange(new Control[] { before, after, retry, open });
        layout.Controls.Add(buttons);
        status.Margin = new Padding(3, 5, 3, 5);
        status.MaximumSize = new Size(590, 0);
        layout.Controls.Add(status);
        progress.Margin = new Padding(3, 0, 3, 8);
        layout.Controls.Add(progress);
        layout.Controls.Add(activity);

        before.Click += delegate { Measure(false); };
        after.Click += delegate { Measure(true); };
        open.Click += delegate {
            try
            {
                Directory.CreateDirectory(results);
                Process.Start(new ProcessStartInfo(results) { UseShellExecute = true });
            }
            catch (Exception ex) { Append(ex.Message); }
        };
        retry.Click += delegate { Detect(); };
        cards.SelectedIndexChanged += delegate { if (!busy) RefreshState(); };
        Shown += delegate { Detect(); };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (busy && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                MessageBox.Show(this, "Wait for the current operation to finish. The results will be saved automatically.",
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        };
    }

    private string CardDirectory(Gpu gpu)
    {
        return Path.Combine(results, gpu.Uuid.ToLowerInvariant(), gpu.Pci.Replace(':', '-'));
    }

    private string LatestBefore(Gpu gpu)
    {
        string path = CardDirectory(gpu);
        if (!Directory.Exists(path)) return null;
        var entries = Directory.GetDirectories(path, "before-*");
        Array.Sort(entries, StringComparer.Ordinal);
        for (int i = entries.Length - 1; i >= 0; i--)
        {
            string file = Path.Combine(entries[i], "before.json");
            if (File.Exists(Path.Combine(entries[i], "complete")) && File.Exists(file)) return file;
        }
        return null;
    }

    private void RefreshState(string message = null)
    {
        var gpu = cards.SelectedItem as Gpu;
        string saved = null;
        if (!busy && gpu != null)
        {
            try { saved = LatestBefore(gpu); }
            catch (Exception ex) { message = ex.Message; }
        }
        cards.Enabled = !busy && cards.Items.Count > 0;
        before.Enabled = !busy && gpu != null;
        after.Enabled = !busy && saved != null;
        retry.Enabled = !busy;
        retry.Visible = cards.Items.Count == 0;
        open.Enabled = !busy;
        progress.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Blocks;
        status.Text = message ?? (saved == null
            ? "Close games and GPU-heavy apps, then run the before test."
            : "Before result saved. Run after when you're ready to compare.");
        AcceptButton = after.Enabled ? after : (before.Enabled ? before : retry);
    }

    private void Append(string line)
    {
        if (String.IsNullOrWhiteSpace(line)) return;
        activity.AppendText(line + Environment.NewLine);
    }

    private async void Detect()
    {
        if (busy) return;
        busy = true;
        cards.Items.Clear();
        activity.Clear();
        RefreshState("Detecting NVIDIA GPUs...");
        string message = null;
        try
        {
            var found = new List<Gpu>();
            var addresses = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool invalid = false;
            int code = await RunWorker("List", null, null, null, delegate(string line) {
                if (!line.StartsWith("GPU|", StringComparison.Ordinal)) { Append(line); return; }
                var fields = line.Split(new[] { '|' }, 4);
                Guid uuid;
                if (fields.Length != 4 || !Regex.IsMatch(fields[1], @"\A[0-9a-f]{8}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]\z") ||
                    !fields[2].StartsWith("GPU-", StringComparison.OrdinalIgnoreCase) ||
                    !Guid.TryParseExact(fields[2].Substring(4), "D", out uuid) || uuid == Guid.Empty ||
                    !addresses.Add(fields[1]) || !ids.Add(fields[2]) || String.IsNullOrWhiteSpace(fields[3]))
                {
                    invalid = true;
                    return;
                }
                found.Add(new Gpu { Pci = fields[1], Uuid = fields[2], Name = fields[3] });
            });
            if (code != 0 || invalid || found.Count < 1 || found.Count > 2)
                throw new InvalidOperationException("GPU detection failed. Check the details below and retry.");
            cards.Items.AddRange(found.ToArray());
            cards.SelectedIndex = 0;
        }
        catch (Exception ex) { message = ex.Message; }
        busy = false;
        RefreshState(message);
    }

    private async void Measure(bool followup)
    {
        if (busy) return;
        var gpu = cards.SelectedItem as Gpu;
        if (gpu == null) return;
        busy = true;
        activity.Clear();
        string action = followup ? "After" : "Before";
        RefreshState("Starting the " + action.ToLowerInvariant() + " test...");
        string message;
        StreamWriter log = null;
        try
        {
            string saved = followup ? LatestBefore(gpu) : null;
            if (followup && saved == null) throw new InvalidOperationException("Run the before test first.");
            string runName = action.ToLowerInvariant() + "-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff")
                + "-" + Guid.NewGuid().ToString("N").Substring(0, 8);
            string dir = Path.Combine(CardDirectory(gpu), runName);
            Directory.CreateDirectory(dir);
            log = new StreamWriter(Path.Combine(dir, "run.log")) { AutoFlush = true };
            int code = await RunWorker(action, gpu, dir, saved, delegate(string line) {
                Append(line);
                try { log.WriteLine(line); }
                catch (IOException) { }
                if (line.StartsWith("Trial ", StringComparison.Ordinal)) status.Text = "Measuring " + gpu.Name + "...";
                else if (line.StartsWith("Setting up ", StringComparison.Ordinal) ||
                         line.StartsWith("Installing ", StringComparison.Ordinal) ||
                         line.StartsWith("Checking ", StringComparison.Ordinal)) status.Text = line;
            });
            if (code != 0)
            {
                message = followup && IsComplete(Path.Combine(dir, "after.json"))
                    ? "After result saved. See below for the comparison issue."
                    : action + " test stopped. Check the details below and retry.";
            }
            else if (!followup)
            {
                if (!IsComplete(Path.Combine(dir, "before.json")))
                    throw new InvalidDataException("No completed before result was saved. Please retry.");
                using (File.Create(Path.Combine(dir, "complete"))) { }
                message = "Before result saved. Run after when you're ready to compare.";
            }
            else
            {
                if (!File.Exists(Path.Combine(dir, "comparison.json")))
                    throw new InvalidDataException("No comparison was saved. Please retry.");
                message = "Comparison complete. Use Open results to find the saved files.";
            }
        }
        catch (Exception ex)
        {
            Append(ex.Message);
            message = action + " test stopped. Check the details below and retry.";
        }
        finally
        {
            try { if (log != null) log.Dispose(); }
            catch (IOException) { }
        }
        busy = false;
        RefreshState(message);
    }

    private static bool IsComplete(string path)
    {
        if (!File.Exists(path)) return false;
        try
        {
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
            object status;
            return data != null && data.TryGetValue("status", out status) && object.Equals(status, "complete");
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    private async Task<int> RunWorker(string action, Gpu gpu, string dir, string saved, Action<string> output)
    {
        var shell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        var script = Path.Combine(package, @"desktop\benchmark-app\Run-Benchmark.ps1");
        if (!File.Exists(script))
            throw new FileNotFoundException("Extract the entire ZIP, then open RTX Tensor Benchmark.exe from the extracted folder.");
        var args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action;
        if (gpu != null) args += " -Gpu " + Quote(gpu.Pci) + " -OutputDirectory " + Quote(dir);
        if (saved != null) args += " -Before " + Quote(saved);
        var start = new ProcessStartInfo(shell, args) {
            WorkingDirectory = package, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        // Use inbox Windows PowerShell modules even from a customized terminal.
        start.EnvironmentVariables["PSModulePath"] = Path.Combine(Path.GetDirectoryName(shell), "Modules");
        using (var process = Process.Start(start))
        {
            if (process == null) throw new InvalidOperationException("Windows could not start the benchmark worker.");
            var stdout = Drain(process.StandardOutput, output);
            var stderr = Drain(process.StandardError, output);
            var exit = Task.Run(delegate {
                if (action == "List" && !process.WaitForExit(20000))
                {
                    if (!process.HasExited) process.Kill();
                    throw new TimeoutException("The NVIDIA driver did not respond. Close GPU-heavy apps and retry.");
                }
                process.WaitForExit();
                return process.ExitCode;
            });
            var streams = Task.WhenAll(stdout, stderr);
            ExceptionDispatchInfo failure;
            try
            {
                int code = await exit;
                if (await Task.WhenAny(streams, Task.Delay(5000)) != streams)
                    throw new TimeoutException("The benchmark worker did not close its output.");
                await streams;
                return code;
            }
            catch (Exception ex)
            {
                failure = ExceptionDispatchInfo.Capture(ex);
                process.StandardOutput.Close();
                process.StandardError.Close();
            }
            try { await streams; }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            failure.Throw();
            return 1;
        }
    }

    private async Task Drain(StreamReader reader, Action<string> output)
    {
        string line;
        while ((line = await reader.ReadLineAsync()) != null) output(line);
    }

    private static string Quote(string value)
    {
        return "\"" + Regex.Replace(value, "(\\\\*)\"|(\\\\+)$", match => {
            if (match.Groups[1].Success) return match.Groups[1].Value + match.Groups[1].Value + "\\\"";
            return match.Value + match.Value;
        }) + "\"";
    }
}
