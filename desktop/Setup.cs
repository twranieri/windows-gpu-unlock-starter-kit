// SPDX-License-Identifier: GPL-2.0-only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("Windows GPU Unlock Setup")]
[assembly: System.Reflection.AssemblyVersion("0.4.0.13")]

namespace RtxSetup
{
    internal sealed class Card
    {
        public string Label { get; set; }
        public string Bdf { get; set; }
        public string Device { get; set; }
        public int? MemoryMiB { get; set; }
    }

    internal sealed class UsbDrive
    {
        public string Letter { get; set; }
        public string Label { get; set; }
        public ulong FreeBytes { get; set; }
        public ulong TotalBytes { get; set; }
        public string FileSystem { get; set; }
        public string DiskModel { get; set; }
        public string VolumeId { get; set; }
        public override string ToString()
        {
            if (!string.IsNullOrWhiteSpace(FileSystem) && FileSystem != "FAT32")
                return string.Format("{0}:   {1}   ({2}, format required)", Letter,
                    string.IsNullOrWhiteSpace(Label) ? "USB drive" : Label, FileSystem);
            return string.Format("{0}:   {1}   ({2:0.0} GB free)", Letter,
                string.IsNullOrWhiteSpace(Label) ? "USB drive" : Label, FreeBytes / 1e9);
        }
    }

    internal sealed class KitStatus
    {
        public Card[] Targets { get; set; }
        public UsbDrive[] Drives { get; set; }
        public UsbDrive[] FormatDrives { get; set; }
        public string[] BootProblems { get; set; }
        public string[] WindowsDisplayProblems { get; set; }
        public string InventoryError { get; set; }
        public string BundleError { get; set; }
        public string StorageError { get; set; }
        public string PackageError { get; set; }
        public string Platform { get; set; }
        public bool HasPackage { get; set; }
        public bool HasLog { get; set; }
        public bool MediaFailed { get; set; }
        public bool CanBootUnlock { get; set; }
        public bool CompletedUnlockBoot { get; set; }
        public string FirmwareState { get; set; }
        public string FastStartupState { get; set; }
        public bool CanFixFastStartup { get; set; }
        public bool CanDisableEncryption { get; set; }
        public string SystemDrive { get; set; }
        public string EncryptionState { get; set; }
        public string ProtectionState { get; set; }
        public int? EncryptionPercentage { get; set; }
        public string MediaState { get; set; }
        public string MediaTitle { get; set; }
        public string MediaMessage { get; set; }
    }

    internal sealed class BackendResult
    {
        public int ExitCode;
        public string Output;
        public string Error;
    }

    internal sealed class MeasureStatus
    {
        public string Status { get; set; }
        public string Message { get; set; }
        public string Python { get; set; }
        public string ResultsDirectory { get; set; }
        public string BootId { get; set; }
        public bool BootConfirmed { get; set; }
        public bool HasComparisonForBoot { get; set; }
        public bool CanProvision { get; set; }
        public string ProvisionMessage { get; set; }
        public MeasureCard[] Cards { get; set; }
    }

    internal sealed class MeasureCard
    {
        public string Bdf { get; set; }
        public string Label { get; set; }
        public bool HasStock { get; set; }
        public bool CanStock { get; set; }
        public bool CanUnlocked { get; set; }
        public bool HasComparisonForBoot { get; set; }
        public string Message { get; set; }
        public Dictionary<string, MeasureMode> Modes { get; set; }
    }

    internal sealed class MeasureMode
    {
        public double speed_ratio { get; set; }
    }

    internal sealed class SetupWindow : Form
    {
        private static readonly Color Canvas = Color.FromArgb(19, 24, 35);
        private static readonly Color PanelColor = Color.FromArgb(28, 36, 51);
        private static readonly Color Accent = Color.FromArgb(119, 225, 177);
        private static readonly Color Ink = Color.FromArgb(240, 244, 248);
        private static readonly Color Muted = Color.FromArgb(174, 188, 208);
        private static readonly Color Warning = Color.FromArgb(255, 199, 124);
        private readonly string root = AppDomain.CurrentDomain.BaseDirectory;
        private readonly ComboBox drives = new ComboBox();
        private readonly Label cards = new Label();
        private readonly Label prerequisites = new Label();
        private readonly Label phase = new Label();
        private readonly Label next = new Label();
        private readonly Label cacheLabel = new Label();
        private readonly TextBox activity = new TextBox();
        private readonly Button primary = MakeButton("Prepare probe USB", true);
        private readonly Button refresh = MakeButton("Refresh", false);
        private readonly Button restore = MakeButton("Restore probe", false);
        private readonly Button offline = MakeButton("Offline inputs", false);
        private readonly Button bootLog = MakeButton("Open USB log", false);
        private readonly Button diagnostics = MakeButton("Open diagnostics", false);
        private readonly Button benchmark = MakeButton("Tensor benchmarks", false);
        private const string ResumeOptionText = "Reopen Setup at next sign-in after a setup change";
        private static readonly string BuildVersion = typeof(SetupWindow).Assembly.GetName().Version.ToString();
        private const string BuildMismatch = "Setup executable and scripts are from different builds.";
        private const string BenchmarkDownload = "If Setup cannot find a CUDA Python environment, it downloads about 2.7 GB to set up a private one and installs the Microsoft Visual C++ runtime if needed.";
        private readonly CheckBox reopen = new CheckBox
        {
            Text = ResumeOptionText,
            Checked = true, Dock = DockStyle.Fill, ForeColor = Muted
        };
        private bool reopenPreference = true;
        private bool resumeDisarmed;
        private bool resumeCleanupComplete;
        private string lastResumeCleanupError;
        private readonly System.Windows.Forms.Timer decryptRefresh = new System.Windows.Forms.Timer { Interval = 15000 };
        private readonly CheckBox automaticBenchmarks = new CheckBox
        {
            Text = "Run tensor tests before and after unlock", Dock = DockStyle.Fill, ForeColor = Muted
        };
        private readonly HashSet<string> automaticRuns = new HashSet<string>(StringComparer.Ordinal);
        private string benchmarkPython;
        private const string RecoverySteps = "Fully power off, remove the USB, then start Windows Boot Manager directly. " +
            "After Windows returns, reconnect the USB and save its boot log before restoring the probe if you need the log.";
        private KitStatus state;
        private string lastReportedFailure;
        private string lastDiagnosticsPath;
        private bool busy;
        private string inputCache;
        private string nextAction;
        private string requestedVolume;

        public SetupWindow(string resumeVolume)
        {
            requestedVolume = resumeVolume;
            Text = "Windows GPU Unlock Setup " + BuildVersion;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(1060, 770);
            MinimumSize = new Size(880, 690);
            BackColor = Canvas;
            ForeColor = Ink;
            Font = new Font("Segoe UI", 10);

            var frame = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Padding = new Padding(22) };
            frame.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 224));
            frame.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            frame.RowStyles.Add(new RowStyle(SizeType.Absolute, 90));
            frame.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            Controls.Add(frame);

            var masthead = new Panel { Dock = DockStyle.Fill };
            masthead.Controls.Add(new Label { Text = "Windows GPU Unlock", Font = new Font("Segoe UI Semibold", 25), ForeColor = Ink, Location = new Point(0, 3), AutoSize = true });
            masthead.Controls.Add(new Label { Text = "Experimental RTX 30 and 40 series setup", ForeColor = Accent, Location = new Point(2, 52), AutoSize = true });
            frame.Controls.Add(masthead, 0, 0);
            frame.SetColumnSpan(masthead, 2);

            var rail = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, BackColor = PanelColor, Padding = new Padding(16), Margin = new Padding(0, 0, 16, 0) };
            rail.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            frame.Controls.Add(rail, 0, 1);
            AddRail(rail, "SETUP PATH", Accent, 31);
            AddRail(rail, "01   Check this PC", Ink, 37);
            AddRail(rail, "02   Prepare probe USB", Ink, 37);
            AddRail(rail, "03   USB boot 1: read-only test", Ink, 43);
            AddRail(rail, "04   USB boot 2: unlock", Ink, 37);
            AddRail(rail, "05   View the results", Ink, 37);
            AddRail(rail, "Setup reads the USB log and shows the next step.", Muted, 49);
            AddRail(rail, "RECOVERY", Accent, 32);
            AddRail(rail, "Power off, remove the USB, then choose Windows Boot Manager.", Muted, 80);
            var guide = MakeButton("Boot and recovery help", false);
            guide.Dock = DockStyle.Top;
            guide.Click += async delegate { await RefreshHelp(ShowBootHelp); };
            rail.Controls.Add(guide);
            var recovery = MakeButton("Recovery steps", false);
            recovery.Dock = DockStyle.Top;
            recovery.Click += delegate { MessageBox.Show(this, RecoverySteps, "Recovery steps", MessageBoxButtons.OK, MessageBoxIcon.Information); };
            rail.Controls.Add(recovery);
            var bios = MakeButton("BIOS settings help", false);
            bios.Dock = DockStyle.Top;
            bios.Click += async delegate { await RefreshHelp(ShowBiosHelp); };
            rail.Controls.Add(bios);

            var details = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 12, Padding = new Padding(18), BackColor = PanelColor, AutoScroll = true };
            details.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            frame.Controls.Add(details, 1, 1);
            AddLine(details, "DETECTED HARDWARE", Accent, 26);
            AddText(details, cards, "Checking installed NVIDIA GPUs...", Ink, 68);
            AddText(details, prerequisites, "Reading boot settings...", Muted, 68);
            AddLine(details, "DEDICATED USB DRIVE", Accent, 26);
            drives.DropDownStyle = ComboBoxStyle.DropDownList;
            drives.AccessibleName = "Dedicated USB drive";
            drives.Dock = DockStyle.Fill;
            drives.SelectionChangeCommitted += async delegate
            {
                requestedVolume = null;
                await RunFlow(null, true);
            };
            details.RowStyles.Add(new RowStyle(SizeType.Absolute, 35));
            details.Controls.Add(drives);
            AddText(details, phase, "Checking this PC", Accent, 30);
            phase.Font = new Font("Segoe UI Semibold", 13);
            AddText(details, next, "", Ink, 108);
            var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = true };
            actions.Controls.AddRange(new Control[] { primary, refresh, restore, benchmark, offline, bootLog, diagnostics });
            details.RowStyles.Add(new RowStyle(SizeType.Absolute, 88));
            details.Controls.Add(actions);
            AddText(details, cacheLabel, "First-time setup downloads pinned firmware inputs. The app verifies them before use.", Muted, 38);
            details.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            details.Controls.Add(reopen);
            details.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            automaticBenchmarks.Checked = ReadAutomaticBenchmarks();
            details.Controls.Add(automaticBenchmarks);
            automaticBenchmarks.CheckedChanged += delegate { SaveAutomaticBenchmarks(); };
            activity.Dock = DockStyle.Fill;
            activity.Multiline = true;
            activity.ReadOnly = true;
            activity.ScrollBars = ScrollBars.Vertical;
            activity.WordWrap = true;
            activity.Font = new Font("Consolas", 9);
            activity.BackColor = Canvas;
            activity.ForeColor = Ink;
            activity.AccessibleName = "Setup activity";
            details.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            details.Controls.Add(activity);

            primary.Click += async delegate
            {
                if (nextAction == "ExtractHelp") ShowExtractionSteps(this);
                else if (nextAction == "Help") await RefreshHelp(ShowBootHelp);
                else if (nextAction == "BiosHelp") await RefreshHelp(ShowBiosHelp);
                else if (nextAction == "Benchmarks") OpenBenchmarks();
                else if (nextAction != null) await RunFlow(nextAction);
            };
            reopen.CheckedChanged += delegate
            {
                if (resumeDisarmed) return;
                reopenPreference = reopen.Checked;
                if (!reopen.Checked)
                {
                    try { Resume.Cancel(); }
                    catch (Exception error) { Append("Could not remove the one-time resume entry. " + error.Message); }
                }
            };
            decryptRefresh.Tick += async delegate { await RunFlow(null); };
            refresh.Click += async delegate { await RunFlow(null, true); };
            restore.Click += async delegate { await RunFlow("RestoreProbe"); };
            benchmark.Click += delegate { OpenBenchmarks(); };
            var offlineMenu = new ContextMenuStrip();
            offline.ContextMenuStrip = offlineMenu;
            offline.Click += delegate { offlineMenu.Show(offline, new Point(0, offline.Height)); };
            offlineMenu.Items.Add("Choose archive folder", null, delegate
            {
                using (var chooser = new FolderBrowserDialog { Description = "Select the folder containing both exact pinned input archives.", ShowNewFolderButton = false })
                {
                    if (chooser.ShowDialog(this) == DialogResult.OK)
                    {
                        inputCache = chooser.SelectedPath;
                        cacheLabel.Text = "Offline archive folder selected. The app verifies both files before use.";
                    }
                }
            });
            offlineMenu.Items.Add("Download pinned archives", null, delegate
            {
                if (MessageBox.Show(this, "Open both pinned archives in your browser? Save them in the same folder, then choose Archive folder under Offline inputs.", Text, MessageBoxButtons.OKCancel) != DialogResult.OK) return;
                try
                {
                    OpenLink("https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz");
                    OpenLink("https://archive.archlinux.org/packages/n/nvidia-utils/nvidia-utils-610.43.03-1-x86_64.pkg.tar.zst");
                }
                catch (Exception error) { MessageBox.Show(this, error.Message, Text); }
            });
            bootLog.Click += delegate
            {
                UsbDrive usb = drives.SelectedItem as UsbDrive;
                if (usb != null) OpenFile(usb.Letter + @":\loader.log");
            };
            diagnostics.Click += async delegate
            {
                if (busy) return;
                busy = true;
                UpdateButtons();
                try
                {
                    if (File.Exists(lastDiagnosticsPath)) OpenFile(lastDiagnosticsPath);
                    else await OpenDiagnostics("Requested by user", SetupDiagnostics.GetCheckFailure(state), drives.SelectedItem as UsbDrive, true);
                }
                finally { busy = false; UpdateButtons(); }
            };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (busy && e.CloseReason == CloseReason.UserClosing)
                {
                    e.Cancel = true;
                    MessageBox.Show(this, "Wait for the current check or file operation to finish.", Text);
                }
            };
            FormClosed += delegate { decryptRefresh.Dispose(); };
            UpdateButtons();
        }

        protected override async void OnShown(EventArgs e)
        {
            base.OnShown(e);
            await RunFlow(null, true);
        }

        private static void AddRail(TableLayoutPanel panel, string value, Color color, int height)
        {
            AddText(panel, new Label(), value, color, height);
        }

        private static void AddLine(TableLayoutPanel panel, string value, Color color, int height)
        {
            AddText(panel, new Label(), value, color, height);
        }

        private static void AddText(TableLayoutPanel panel, Label label, string value, Color color, int height)
        {
            label.Text = value;
            label.ForeColor = color;
            label.Dock = DockStyle.Fill;
            label.AutoEllipsis = true;
            label.Margin = new Padding(0, 3, 0, 0);
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            panel.Controls.Add(label);
        }

        private static Button MakeButton(string text, bool prominent)
        {
            var button = new Button { Text = text, AutoSize = true, Height = 33, FlatStyle = FlatStyle.Flat,
                BackColor = prominent ? Accent : Canvas, ForeColor = prominent ? Canvas : Ink,
                Margin = new Padding(0, 4, 8, 4), Padding = new Padding(7, 0, 7, 0), UseVisualStyleBackColor = false };
            button.FlatAppearance.BorderColor = prominent ? Accent : Color.FromArgb(77, 91, 113);
            return button;
        }

        private void UpdateButtons()
        {
            primary.Enabled = !busy && nextAction != null;
            refresh.Enabled = !busy;
            drives.Enabled = !busy;
            bool usableSetup = state != null && (state.HasPackage || string.IsNullOrWhiteSpace(state.BundleError));
            offline.Enabled = !busy && usableSetup;
            benchmark.Enabled = !busy && usableSetup;
            reopen.Enabled = !busy && !resumeDisarmed;
            automaticBenchmarks.Enabled = !busy;
            restore.Visible = state != null && state.HasPackage &&
                (state.MediaState == "Recoverable" || state.MediaState == "UnlockStaged" || state.MediaState == "UnlockLogged");
            restore.Enabled = !busy;
            bootLog.Enabled = !busy && state != null && state.HasLog;
            diagnostics.Enabled = !busy;
            UseWaitCursor = busy;
            decryptRefresh.Enabled = !busy && state != null && state.EncryptionState == "DecryptionInProgress";
        }

        private async Task RunFlow(string action, bool checkAutomaticUnlocked = false)
        {
            if (busy) return;
            var usb = drives.SelectedItem as UsbDrive;
            if (action == "FormatUsb")
            {
                var eligible = FindFormatDrive(state, usb);
                if (nextAction != "FormatUsb" || eligible == null || !HasVerifiedBootPrerequisites(state, true) ||
                    (eligible.FileSystem == "FAT32" && !CanFormatBlockedFat32(state, eligible, KitTargetListMissing)))
                {
                    MessageBox.Show(this, "The selected USB is no longer eligible to format. Refresh and select the intended drive.",
                        Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                usb = eligible;
            }
            var letter = usb == null ? null : usb.Letter;
            string preferredVolume = usb == null ? requestedVolume : usb.VolumeId;
            bool windowsAction = action == "FixFastStartup" || action == "DisableEncryption";
            bool fixFastStartupAfterFormat = action == "FormatUsb" && state.CanFixFastStartup;
            bool disableEncryptionAfterAction = (action == "FormatUsb" || action == "FixFastStartup") && state.CanDisableEncryption;
            if (action != null)
            {
                if (!windowsAction && (usb == null || string.IsNullOrEmpty(usb.VolumeId))) return;
                if (!ConfirmAction(action, usb, fixFastStartupAfterFormat, disableEncryptionAfterAction)) return;
            }
            busy = true;
            UpdateButtons();
            string failure = null;
            string unexpectedFailure = null;
            bool justFormatted = false;
            try
            {
                bool completed = false;
                if (action != null)
                {
                    if (action == "StageUnlock" && !await ResolveStockBeforeStaging(
                        () => RunAutomaticBenchmark("Stock", usb, true), ShowStockBenchmarkOptions))
                    {
                        next.Text = "The unlock USB was not prepared. Click Prepare unlock USB to try again, or open Tensor benchmarks to check the stock test.";
                        Append(next.Text);
                        return;
                    }
                    Append("Running " + action + (windowsAction ? " in Windows." : " on " + letter + ":"));
                    var result = await RunBackend(action, windowsAction ? null : letter, windowsAction ? null : usb.VolumeId);
                    completed = result.ExitCode == 0;
                    if (!completed)
                    {
                        failure = "Setup engine exit code " + result.ExitCode + Environment.NewLine + result.Error;
                        Append("Operation stopped. Review the activity above.");
                    }
                    justFormatted = completed && action == "FormatUsb";
                    if (justFormatted && fixFastStartupAfterFormat)
                    {
                        Append("FAT32 format verified. Turning off Windows Fast Startup.");
                        failure = await RunWindowsFollowup("FixFastStartup", "FAT32 format verified. Setup could not turn off Windows Fast Startup.");
                        if (failure != null) Append(failure);
                    }
                    if (completed && failure == null && disableEncryptionAfterAction)
                    {
                        Append("Starting BitLocker decryption on " + state.SystemDrive + ".");
                        string message = justFormatted ? "FAT32 format verified. " : "";
                        failure = await RunWindowsFollowup("DisableEncryption", message + "Setup could not start BitLocker decryption.");
                        if (failure != null) Append(failure);
                    }
                }
                state = await ReadStatus(letter);
                var selected = FindRefreshDrive(GetDrives(state), preferredVolume, justFormatted ? letter : null);
                string selection = selected == null ? null : selected.Letter;
                if (selection != letter)
                {
                    state = await ReadStatus(selection);
                    if (selected != null)
                    {
                        var checkedDrive = FindRefreshDrive(GetDrives(state), selected.VolumeId, null);
                        if (checkedDrive == null || checkedDrive.Letter != selection)
                        {
                            preferredVolume = selected.VolumeId;
                            selection = null;
                            state = await ReadStatus(null);
                        }
                    }
                }
                requestedVolume = selection == null && !justFormatted ? preferredVolume : null;
                if (justFormatted && fixFastStartupAfterFormat && state.FastStartupState != "Disabled" && failure == null)
                {
                    failure = "FAT32 format verified. Windows Fast Startup could not be confirmed off after refreshing.";
                    Append(failure);
                }
                if (completed && (disableEncryptionAfterAction || action == "DisableEncryption") && failure == null &&
                    !IsFullyDecrypted(state) && state.EncryptionState != "DecryptionInProgress")
                {
                    failure = "Setup could not verify that Windows started BitLocker decryption.";
                    Append(failure);
                }
                ShowStatus(selection);
                UpdateResumeAfterFlow(action, completed);
                var currentUsb = drives.SelectedItem as UsbDrive;
                var checkFailure = lastResumeCleanupError ?? SetupDiagnostics.GetCheckFailure(state, nextAction == "FormatUsb");
                if (failure != null || checkFailure != null)
                    await OpenDiagnostics(action ?? "Setup check", failure ?? checkFailure, currentUsb ?? usb, action != null);
                else
                    lastReportedFailure = null;
                if (completed && (windowsAction || action == "FormatUsb" ||
                    ((action == "Prepare" || action == "RestoreProbe") && state.MediaState == "ProbeStaged") ||
                    (action == "StageUnlock" && state.CanBootUnlock))) ArmResume();
                var benchmarkUsb = currentUsb;
                if (completed && action == "Prepare" && state.MediaState == "ProbeStaged")
                {
                    if (!await RunAutomaticBenchmark("Stock", benchmarkUsb))
                    {
                        next.Text = "The stock benchmark did not finish. You can still do USB boot 1: the read-only test. Click Show first USB boot. Setup will offer a benchmark retry before preparing the unlock USB.";
                        Append(next.Text);
                    }
                }
                else if (checkAutomaticUnlocked && benchmarkUsb != null && state.MediaState == "UnlockLogged" &&
                    HasVerifiedBootPrerequisites(state))
                    await RunAutomaticBenchmark("Unlocked", benchmarkUsb);
            }
            catch (Exception error)
            {
                state = null;
                nextAction = null;
                phase.Text = "Setup check failed";
                next.Text = justFormatted ? "FAT32 format verified. Click Refresh before continuing. " + error.Message : error.Message;
                if (error.Message == BuildMismatch) OfferExtractionHelp(BuildMismatch);
                Append(error.Message);
                unexpectedFailure = failure ?? error.Message;
            }
            finally
            {
                if (unexpectedFailure == null)
                {
                    busy = false;
                    UpdateButtons();
                }
            }
            if (unexpectedFailure == null) return;
            try { await OpenDiagnostics(action ?? "Setup check", unexpectedFailure, usb, action != null); }
            finally { busy = false; UpdateButtons(); }
        }

        private async Task<string> RunWindowsFollowup(string action, string message)
        {
            try
            {
                var result = await RunBackend(action, null, null);
                return result.ExitCode == 0 ? null : message + Environment.NewLine + result.Error;
            }
            catch (Exception error)
            {
                return message + Environment.NewLine + error.Message;
            }
        }

        private async Task OpenDiagnostics(string step, string detail, UsbDrive usb, bool force, Action<string> notify = null, bool openReport = true)
        {
            var key = step + "\n" + detail + "\n" + (usb == null ? null : usb.VolumeId);
            if (!force && lastReportedFailure == key) return;
            if (notify == null) notify = Append;
            var snapshot = state;
            try
            {
                var path = await Task.Run(() => SetupDiagnostics.Save(root, step, detail, snapshot, usb));
                lastReportedFailure = key;
                lastDiagnosticsPath = path;
                notify("Diagnostics saved. Use Open diagnostics in Setup to view the latest report. " + path);
                if (openReport) OpenFile(path);
            }
            catch (Exception error)
            {
                notify("Setup could not save the diagnostic report. " + error.Message);
            }
        }

        private bool ConfirmAction(string action, UsbDrive usb, bool fixFastStartupAfterFormat, bool disableEncryptionAfterAction)
        {
            string prompt;
            switch (action)
            {
                case "FixFastStartup":
                    prompt = "Turn off Windows Fast Startup so Shut down can give the USB a cold boot?";
                    break;
                case "DisableEncryption":
                    prompt = "Turn off BitLocker or Device Encryption on " + state.SystemDrive + "? Windows will decrypt the system drive and remove its protection. " +
                        "Save your recovery key and allow decryption to finish before changing BIOS settings.";
                    break;
                case "FormatUsb":
                    prompt = string.Format("Erase every file on USB {0}: ({1}, {2}, {3:0.0} GB) and format it as FAT32? Check the letter and size before confirming.",
                        usb.Letter, string.IsNullOrWhiteSpace(usb.Label) ? "unnamed drive" : usb.Label, usb.DiskModel, usb.TotalBytes / 1e9);
                    if (fixFastStartupAfterFormat)
                        prompt += "\r\n\r\nAfter verifying the format, Setup will also turn off Windows Fast Startup and verify the setting.";
                    break;
                case "Prepare":
                    prompt = "Prepare the read-only probe on " + usb + "? Use a dedicated, backed-up USB drive.";
                    if (automaticBenchmarks.Checked)
                        prompt += "\r\n\r\n" + BenchmarkDownload + " Setup then runs any needed stock tensor tests. Use a normal Windows Boot Manager boot and close GPU-heavy apps first.";
                    break;
                case "StageUnlock":
                    prompt = "Setup read the USB log and found that the read-only test passed. Click OK if Windows opened on its own after that boot. " +
                        "Setup will prepare " + usb + " for USB boot 2. Preparing the USB does not change your GPUs.";
                    if (automaticBenchmarks.Checked)
                        prompt += "\r\n\r\nSetup will run any missing stock benchmarks first. If a test fails, you can retry or continue without that comparison.";
                    break;
                default:
                    prompt = "Restore the verified read-only probe on " + usb + "? This clears the old USB boot log. Save a copy first if you need it.";
                    break;
            }
            if (disableEncryptionAfterAction)
                prompt += "\r\n\r\nSetup will also start turning off BitLocker or Device Encryption on " + state.SystemDrive +
                    ". Windows will decrypt that drive and remove its protection. Keep Windows running until Setup verifies that decryption is complete.";
            bool sensitive = action == "FormatUsb" || action == "DisableEncryption" || disableEncryptionAfterAction;
            return MessageBox.Show(this, prompt, Text, MessageBoxButtons.OKCancel,
                sensitive ? MessageBoxIcon.Warning : MessageBoxIcon.Information,
                sensitive ? MessageBoxDefaultButton.Button2 : MessageBoxDefaultButton.Button1) == DialogResult.OK;
        }

        private static List<UsbDrive> GetDrives(KitStatus status)
        {
            var items = new List<UsbDrive>(status.Drives);
            foreach (var drive in status.FormatDrives ?? new UsbDrive[0])
                if (drive.FileSystem != "FAT32" && items.Find(item => item.Letter == drive.Letter) == null)
                    items.Add(drive);
            return items;
        }

        private static UsbDrive FindRefreshDrive(List<UsbDrive> drives, string preferredVolume, string formattedLetter)
        {
            // Formatting can give this partition a new volume ID. Only a completed
            // explicit format permits selection by its former letter.
            if (formattedLetter != null) return drives.Find(drive => drive.Letter == formattedLetter);
            if (string.IsNullOrEmpty(preferredVolume)) return drives.Count == 1 ? drives[0] : null;
            var matches = drives.FindAll(drive => string.Equals(drive.VolumeId, preferredVolume, StringComparison.Ordinal));
            return matches.Count == 1 ? matches[0] : null;
        }

        private static UsbDrive FindFormatDrive(KitStatus status, UsbDrive selected)
        {
            if (status == null || status.FormatDrives == null || selected == null || string.IsNullOrEmpty(selected.VolumeId))
                return null;
            UsbDrive match = null;
            foreach (var drive in status.FormatDrives)
            {
                if (drive.Letter != selected.Letter || !string.Equals(drive.VolumeId, selected.VolumeId, StringComparison.Ordinal))
                    continue;
                if (match != null) return null;
                match = drive;
            }
            return match;
        }

        private static bool CanFormatBlockedFat32(KitStatus status, UsbDrive eligible, Func<string, bool> targetListMissing)
        {
            return status != null && status.MediaState == "Blocked" && eligible != null &&
                eligible.FileSystem == "FAT32" && targetListMissing(eligible.Letter);
        }

        private static bool KitTargetListMissing(string letter)
        {
            if (string.IsNullOrEmpty(letter) || letter.Length != 1 || letter[0] < 'D' || letter[0] > 'Z') return false;
            try { File.GetAttributes(letter + @":\kit-targets.txt"); }
            catch (FileNotFoundException) { return true; }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return false;
        }

        private static bool IsFullyDecrypted(KitStatus status)
        {
            return status != null && status.EncryptionState == "FullyDecrypted" &&
                status.ProtectionState == "Off" && status.EncryptionPercentage == 0;
        }

        private static bool HasVerifiedBootPrerequisites(KitStatus status, bool allowWindowsFixes = false)
        {
            if (status == null || status.BootProblems == null) return false;
            bool pendingFastStartup = allowWindowsFixes && status.CanFixFastStartup &&
                (status.FastStartupState == "Enabled" || status.FastStartupState == "NotConfigured");
            bool pendingEncryption = allowWindowsFixes && status.CanDisableEncryption;
            int expectedProblems = (pendingFastStartup ? 1 : 0) + (pendingEncryption ? 1 : 0);
            return (IsFullyDecrypted(status) || pendingEncryption) && status.FirmwareState == "Ready" &&
                (status.FastStartupState == "Disabled" || pendingFastStartup) && status.BootProblems.Length == expectedProblems &&
                status.WindowsDisplayProblems != null && status.WindowsDisplayProblems.Length == 0 &&
                string.IsNullOrWhiteSpace(status.InventoryError) && string.IsNullOrWhiteSpace(status.PackageError) &&
                string.IsNullOrWhiteSpace(status.StorageError);
        }

        private async Task<KitStatus> ReadStatus(string letter)
        {
            var result = await RunBackend("Status", letter, null);
            if (result.ExitCode != 0)
            {
                string error = result.Error ?? "";
                if (error.Contains(BuildMismatch) || (error.Contains("DesktopBuild") && error.Contains("NamedParameterNotFound")))
                    throw new InvalidOperationException(BuildMismatch);
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "Setup check exited with code " + result.ExitCode : error.Trim());
            }
            var status = new JavaScriptSerializer().Deserialize<KitStatus>(result.Output);
            if (status == null || status.Targets == null || status.Drives == null || status.BootProblems == null)
                throw new InvalidOperationException("The setup engine returned an incomplete status.");
            return status;
        }

        private void ShowStatus(string selectedLetter)
        {
            var available = GetDrives(state);
            drives.BeginUpdate();
            drives.Items.Clear();
            foreach (var drive in available)
            {
                drives.Items.Add(drive);
                if (drive.Letter == selectedLetter) drives.SelectedItem = drive;
            }
            drives.EndUpdate();

            var hardware = new List<string>();
            foreach (var card in state.Targets)
            {
                string memory = card.MemoryMiB.HasValue ? string.Format("{0:N0} MiB (driver)", card.MemoryMiB.Value) : "VRAM reading unavailable";
                hardware.Add(string.Format("{0}   {1}   PCI {2}   ID {3}", card.Label, memory, card.Bdf, card.Device));
            }
            if (hardware.Count > 0 && !string.IsNullOrEmpty(state.Platform)) hardware.Add(state.Platform);
            cards.Text = hardware.Count > 0 ? string.Join(Environment.NewLine, hardware) : state.InventoryError;

            var blockers = new List<string>(state.BootProblems);
            if (state.WindowsDisplayProblems != null) blockers.AddRange(state.WindowsDisplayProblems);
            foreach (string error in new[] { state.InventoryError, state.StorageError, state.PackageError })
                if (!string.IsNullOrWhiteSpace(error)) blockers.Add(error);
            if (!state.HasPackage && !string.IsNullOrWhiteSpace(state.BundleError)) blockers.Add(state.BundleError);
            prerequisites.Text = blockers.Count == 0 ? "Windows checks passed. The USB probe checks this PC in UEFI." : string.Join(Environment.NewLine, blockers);
            prerequisites.ForeColor = blockers.Count == 0 ? Muted : Warning;
            nextAction = null;
            phase.Text = "Select a USB drive";
            next.Text = string.IsNullOrWhiteSpace(state.MediaMessage) ? "Insert a dedicated FAT32 USB drive and click Refresh." : state.MediaMessage;
            switch (state.MediaState)
            {
                case "Empty":
                    phase.Text = "Ready to prepare the probe";
                    next.Text = blockers.Count == 0
                        ? "Click Prepare probe USB. Setup downloads what it needs and verifies the USB files. Use Tensor benchmarks to check or run the stock test before unlocking."
                        : "Complete the Windows checks above before preparing the probe USB.";
                    if (blockers.Count == 0) nextAction = "Prepare";
                    break;
                case "ProbeStaged":
                    phase.Text = "USB boot 1: read-only test";
                    if (!state.MediaFailed)
                        next.Text = "Click Show first USB boot. This test checks the GPUs without changing them. When Windows returns, reopen Setup and click Refresh.";
                    nextAction = "Help";
                    break;
                case "ProbePassed":
                    phase.Text = "Probe passed";
                    next.Text = blockers.Count == 0
                        ? "Setup found the read-only result in the USB log. If Windows opened normally after that boot, click Prepare unlock USB. The unlock only runs on the second USB boot."
                        : "The probe passed. Complete the Windows checks above before staging the unlock.";
                    if (blockers.Count == 0) nextAction = "StageUnlock";
                    break;
                case "UnlockStaged":
                    phase.Text = "USB boot 2: unlock";
                    if (state.CanBootUnlock)
                        next.Text = "The unlock USB is ready. Click Show second USB boot. Confirm the unlock at the prompt, then reopen Setup when Windows returns.";
                    nextAction = "Help";
                    break;
                case "UnlockLogged":
                    phase.Text = "Latest USB boot log";
                    if (state.CompletedUnlockBoot)
                    {
                        next.Text = "Setup matched the USB log to this Windows startup. Click View benchmark results to see your comparison or run the after test.";
                        nextAction = "Benchmarks";
                    }
                    else
                    {
                        nextAction = "Help";
                        if (!state.MediaFailed)
                            next.Text = "Setup found an unlock log but could not verify it for this Windows startup. Click Show recovery steps.";
                    }
                    break;
                case "Recoverable":
                    phase.Text = "Restore the probe to resume";
                    break;
                case "Blocked":
                    phase.Text = "USB needs attention";
                    break;
            }
            if (!string.IsNullOrWhiteSpace(state.MediaTitle) &&
                (state.MediaState != "ProbeStaged" || state.MediaFailed) &&
                (state.MediaState != "UnlockStaged" || !state.CanBootUnlock))
                phase.Text = state.CompletedUnlockBoot ? "USB boot matched this Windows startup" : state.MediaTitle;
            if (available.Count == 0 && string.IsNullOrEmpty(state.StorageError))
            {
                phase.Text = "No eligible USB drive found";
                next.Text = "Plug in a spare 8–32 GB USB drive and click Refresh.";
                nextAction = "Help";
            }
            if (requestedVolume != null && selectedLetter == null)
            {
                phase.Text = "Reconnect the setup USB";
                next.Text = "Plug the same USB drive back in and click Refresh to resume.";
            }
            var selected = drives.SelectedItem as UsbDrive;
            var eligibleFormat = FindFormatDrive(state, selected);
            if (state.MediaState == "Blocked" && selected != null && eligibleFormat == null &&
                Array.Exists(state.Drives, drive => drive.Letter == selected.Letter) && KitTargetListMissing(selected.Letter))
            {
                next.Text += " This USB is already FAT32. Back up and verify its files first, then clear the old files in File Explorer and click Refresh.";
            }
            if (nextAction != "Help" && (selected == null || string.IsNullOrEmpty(selected.VolumeId))) nextAction = null;
            bool canConfigure = state.Targets.Length > 0 && string.IsNullOrEmpty(state.InventoryError) &&
                (state.HasPackage || string.IsNullOrEmpty(state.BundleError));
            if (canConfigure && eligibleFormat != null && HasVerifiedBootPrerequisites(state, true) &&
                (eligibleFormat.FileSystem != "FAT32" || CanFormatBlockedFat32(state, eligibleFormat, KitTargetListMissing)))
            {
                phase.Text = "Format this USB as FAT32";
                next.Text = "Check the USB letter and size, then click Format USB. This erases the selected USB.";
                if (state.CanFixFastStartup) next.Text += " Setup will then turn off Windows Fast Startup.";
                if (state.CanDisableEncryption) next.Text += " Setup will also start BitLocker decryption.";
                nextAction = "FormatUsb";
            }
            else if (canConfigure && state.CanFixFastStartup)
            {
                phase.Text = state.CanDisableEncryption ? "Fix Windows settings" : "Turn off Fast Startup";
                next.Text = state.CanDisableEncryption
                    ? "Click Fix Windows settings. Setup will turn off Windows Fast Startup and start BitLocker decryption after you confirm."
                    : "Click Turn off Fast Startup. Setup will change the Windows setting and verify it.";
                nextAction = "FixFastStartup";
            }
            else if (canConfigure && state.CanDisableEncryption)
            {
                phase.Text = "Turn off BitLocker";
                next.Text = "The Windows drive must finish decrypting before the probe can start. Click Turn off BitLocker to begin, then leave Windows running.";
                nextAction = "DisableEncryption";
            }
            else if (state.EncryptionState == "DecryptionInProgress")
            {
                phase.Text = "Waiting for Windows to decrypt";
                string progress = state.EncryptionPercentage.HasValue
                    ? state.EncryptionPercentage.Value + "% of the drive is still encrypted. " : "";
                next.Text = progress + "Keep Windows running. Setup will check the progress automatically.";
                nextAction = null;
            }
            else if (canConfigure && (state.FirmwareState == "SecureBootOn" || state.FirmwareState == "LegacyOrUnverified"))
            {
                phase.Text = "Check the PC's BIOS settings";
                next.Text = "Click Show BIOS steps. Setup will check what Windows can see after you return.";
                nextAction = "BiosHelp";
            }
            if (!state.HasPackage && !string.IsNullOrWhiteSpace(state.BundleError))
            {
                OfferExtractionHelp("Setup could not verify its files. Click Show extraction steps for a clean local copy.");
            }
            if (nextAction == "FixFastStartup") primary.Text = state.CanDisableEncryption ? "Fix Windows settings" : "Turn off Fast Startup";
            else if (nextAction == "DisableEncryption") primary.Text = "Turn off BitLocker";
            else if (nextAction == "BiosHelp") primary.Text = "Show BIOS steps";
            else if (nextAction == "ExtractHelp") primary.Text = "Show extraction steps";
            else if (nextAction == "FormatUsb") primary.Text = "Format USB";
            else if (nextAction == "Prepare") primary.Text = "Prepare probe USB";
            else if (nextAction == "StageUnlock") primary.Text = "Prepare unlock USB";
            else if (nextAction == "Benchmarks") primary.Text = "View benchmark results";
            else if (nextAction == "Help")
            {
                if (available.Count == 0) primary.Text = "USB drive help";
                else primary.Text = state.MediaState == "UnlockLogged" || state.MediaFailed ||
                    (state.MediaState == "UnlockStaged" && !state.CanBootUnlock) || !HasVerifiedBootPrerequisites(state)
                    ? "Show recovery steps" : state.CanBootUnlock ? "Show second USB boot" : "Show first USB boot";
            }
            else if (selected == null) primary.Text = "Select a USB drive";
            else primary.Text = "Setup action unavailable";
            foreach (string blocker in blockers) Append(blocker);
        }

        private void OfferExtractionHelp(string message)
        {
            phase.Text = "Setup files need attention";
            next.Text = message;
            nextAction = "ExtractHelp";
            primary.Text = "Show extraction steps";
        }

        internal static void ShowExtractionSteps(IWin32Window owner)
        {
            MessageBox.Show(owner,
                "1. Close all copies of Setup and download the full installer ZIP.\r\n\r\n" +
                "2. In File Explorer, enter %LOCALAPPDATA% in the address bar and create a new folder there.\r\n\r\n" +
                "3. Right-click the ZIP, choose Extract All, and select that new folder. Open Windows GPU Unlock Setup.exe from the extracted files.",
                "Extract the full Setup ZIP", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private async Task RefreshHelp(Action show)
        {
            if (busy) return;
            await RunFlow(null);
            show();
        }

        private void ShowBootHelp()
        {
            var usb = drives.SelectedItem as UsbDrive;
            if (state != null && GetDrives(state).Count == 0)
            {
                MessageBox.Show(this,
                    "Use a spare USB drive that you can dedicate to this kit. An 8–32 GB drive is enough.\r\n\r\n" +
                    "Open File Explorer → This PC. Right-click the USB drive and choose Properties. Its file system should say FAT32.\r\n\r\n" +
                    "If you need to format it, confirm the USB drive letter and label and save any files you want to keep. Right-click that drive, choose Format, then select FAT32. Formatting erases the selected drive.\r\n\r\n" +
                    "Back in Setup, click Refresh.",
                    "USB drive help", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            const string recovery = "If Windows does not return: " + RecoverySteps;
            bool probeStaged = state != null && state.MediaState == "ProbeStaged";
            bool unlockStaged = state != null && state.CanBootUnlock;
            if ((probeStaged || unlockStaged) && !HasVerifiedBootPrerequisites(state))
            {
                MessageBox.Show(this, "Complete the Windows checks before booting from this USB.\r\n\r\n" +
                    prerequisites.Text + "\r\n\r\n" + RecoverySteps, "Boot prerequisites", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            if (!probeStaged && !unlockStaged)
            {
                string advice = next.Text;
                if (state != null && (state.MediaState == "UnlockStaged" || state.MediaState == "UnlockLogged" ||
                    state.MediaState == "Recoverable"))
                    advice += "\r\n\r\n" + recovery;
                MessageBox.Show(this, advice, "Setup help", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            ArmResume();
            string entry = usb == null || string.IsNullOrWhiteSpace(usb.Label)
                ? "the UEFI entry for your USB drive"
                : "the UEFI entry for your USB drive (" + usb.Label + ")";
            string step = unlockStaged
                ? "At the unlock prompt, press Space or Enter within 30 seconds to confirm, or Esc to skip."
                : "Let the read-only test run. It checks the GPUs without changing them. No unlock confirmation is needed.";
            string boot = "1. Save your work and shut down Windows completely.\r\n\r\n" +
                "2. Turn the PC on. Use the one-time Boot Menu key shown by your PC at startup, then choose " + entry + ".\r\n\r\n" +
                "3. " + step + " Once Windows returns, reopen Setup and click Refresh.";
            if (probeStaged && state.HasLog) boot = next.Text + "\r\n\r\nIf you run the read-only test again:\r\n\r\n" + boot;
            MessageBox.Show(this,
                boot + "\r\n\r\n" + recovery,
                unlockStaged ? "USB boot 2: unlock" : "USB boot 1: read-only test", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void UpdateResumeAfterFlow(string action, bool completed)
        {
            if (state != null && state.CompletedUnlockBoot)
            {
                resumeDisarmed = true;
                reopen.Checked = false;
            }
            else if (resumeDisarmed && completed &&
                (action == "Prepare" || action == "StageUnlock" || action == "RestoreProbe" || action == "FormatUsb"))
            {
                reopen.Checked = reopenPreference;
                resumeDisarmed = false;
                resumeCleanupComplete = false;
                lastResumeCleanupError = null;
                reopen.Text = ResumeOptionText;
            }
            if (!resumeDisarmed || resumeCleanupComplete) return;
            try
            {
                Resume.Cancel();
                resumeCleanupComplete = true;
                lastResumeCleanupError = null;
                reopen.Text = "USB boot matched. Automatic reopening is off.";
                Append("The USB log matches this Windows startup. Setup's one-time reopen entry is cleared.");
            }
            catch (Exception error)
            {
                reopen.Text = "USB boot matched. Refresh to retry removing the reopen entry.";
                if (lastResumeCleanupError != error.Message)
                    Append("Could not remove Setup's one-time reopen entry. Click Refresh to retry. " + error.Message);
                lastResumeCleanupError = error.Message;
            }
        }

        private void ArmResume()
        {
            if (!reopen.Checked || resumeDisarmed || (state != null && state.CompletedUnlockBoot)) return;
            try
            {
                var usb = drives.SelectedItem as UsbDrive;
                Resume.Schedule(Application.ExecutablePath, usb == null ? null : usb.VolumeId);
                Append("Setup will reopen after the next Windows sign-in. Approve the Windows administrator prompt when it appears.");
            }
            catch (Exception error)
            {
                Append("Setup could not schedule automatic reopening. Open it from the extracted folder after signing in. " + error.Message);
            }
        }

        private void ShowBiosHelp()
        {
            if (!IsFullyDecrypted(state))
            {
                MessageBox.Show(this, "Complete the Windows encryption check before changing boot settings. Save your recovery key.",
                    "BIOS settings help", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            string mode = state.FirmwareState == "LegacyOrUnverified"
                ? "Open System Information in Windows and check BIOS Mode. If it says Legacy, leave the settings as they are until Windows has been prepared to boot in UEFI mode.\r\n\r\n"
                : "";
            if (state.FirmwareState != "Ready") ArmResume();
            MessageBox.Show(this,
                mode + "1. Save your work. Open Settings and search for Advanced startup. Choose Restart now, then Troubleshoot → Advanced options → UEFI Firmware Settings. " +
                "You can also use your PC's Setup key at power-on.\r\n\r\n" +
                "2. For a Windows installation already using UEFI, disable Secure Boot and CSM (Legacy Compatibility), then save and exit. " +
                "Use the motherboard or PC manual if the names differ.\r\n\r\n" +
                "3. Start Windows. Sign in, approve the Setup prompt, and check the new status. The read-only USB boot checks GPU initialization in UEFI.",
                "BIOS settings help", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private Task<BackendResult> RunBackend(string action, string letter, string volumeId)
        {
            var executable = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var command = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
                Quote(Path.Combine(root, "RTX.ps1")) + " -Desktop -DesktopBuild " + BuildVersion + " -Action " + action;
            if (!string.IsNullOrEmpty(letter))
            {
                if (letter.Length != 1 || letter[0] < 'D' || letter[0] > 'Z') throw new ArgumentException("Invalid USB letter.");
                command += " -Drive " + letter;
            }
            if (action != "Status") command += " -Execute";
            if (volumeId != null) command += " -VolumeId " + Quote(volumeId);
            if (action == "Prepare" && inputCache != null) command += " -Inputs " + Quote(inputCache);
            return Task.Run(delegate
            {
                var stdout = new StringBuilder();
                var stderr = new StringBuilder();
                using (var process = new Process())
                {
                    process.StartInfo = new ProcessStartInfo(executable, command)
                    {
                        UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root,
                        RedirectStandardOutput = true, RedirectStandardError = true,
                        StandardOutputEncoding = action == "Status" ? Encoding.UTF8 : null
                    };
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data == null) return;
                        if (action == "Status") stdout.AppendLine(e.Data);
                        else BeginInvoke(new Action<string>(Append), e.Data);
                    };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data == null) return;
                        if (stderr.Length < 16000) stderr.AppendLine(e.Data);
                        if (action != "Status") BeginInvoke(new Action<string>(Append), e.Data);
                    };
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    process.WaitForExit();
                    return new BackendResult { ExitCode = process.ExitCode, Output = stdout.ToString(), Error = stderr.ToString() };
                }
            });
        }

        private const string BenchmarkPreferenceKey = @"Software\Windows GPU Unlock";

        private static bool ReadAutomaticBenchmarks()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(BenchmarkPreferenceKey))
                    return key == null || !object.Equals(key.GetValue("AutomaticBenchmarks"), 0);
            }
            catch (Exception) { return true; }
        }

        private void SaveAutomaticBenchmarks()
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(BenchmarkPreferenceKey))
                    key.SetValue("AutomaticBenchmarks", automaticBenchmarks.Checked ? 1 : 0, RegistryValueKind.DWord);
            }
            catch (Exception error) { Append("Setup could not save the automatic benchmark preference. " + error.Message); }
        }

        private Task<BackendResult> RunMeasure(string action, string python, string gpu, UsbDrive usb)
        {
            var script = Path.Combine(root, "desktop", "Measure.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("The benchmark runner is missing. Extract the entire Setup ZIP.");
            var args = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action;
            if (!string.IsNullOrEmpty(python)) args += " -Python " + Quote(python);
            if (!string.IsNullOrEmpty(gpu)) args += " -Gpu " + Quote(gpu);
            if (usb != null && !string.IsNullOrEmpty(usb.VolumeId))
            {
                if (string.IsNullOrEmpty(usb.Letter) || usb.Letter.Length != 1 || usb.Letter[0] < 'D' || usb.Letter[0] > 'Z')
                    throw new ArgumentException("The benchmark USB letter is invalid.");
                args += " -Drive " + usb.Letter + " -VolumeId " + Quote(usb.VolumeId);
            }
            if (action != "Status") args += " -Execute";
            return Task.Run(delegate { return UserProcess.RunPowerShell(root, args); });
        }

        private static MeasureStatus ParseMeasureStatus(BackendResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.Output))
            {
                var report = new JavaScriptSerializer().Deserialize<MeasureStatus>(result.Output);
                if (report != null && report.Cards != null)
                {
                    if (result.ExitCode != 0)
                        throw new InvalidOperationException(report.Message + Environment.NewLine + result.Error);
                    return report;
                }
            }
            var error = string.IsNullOrWhiteSpace(result.Error) ? "The benchmark returned no usable status." : result.Error.Trim();
            throw new InvalidOperationException(error.Length > 1200 ? error.Substring(0, 1200) : error);
        }

        private static bool HasStockForAll(MeasureStatus status)
        {
            return status != null && status.Cards != null && status.Cards.Length > 0 &&
                Array.TrueForAll(status.Cards, card => card.HasStock);
        }

        private static bool CanMeasure(MeasureStatus status, string action, bool automatic)
        {
            if (status == null || status.Cards == null) return false;
            if (action == "Stock")
                return Array.Exists(status.Cards, card => card.CanStock && (!automatic || !card.HasStock));
            if (automatic && status.HasComparisonForBoot) return false;
            return Array.Exists(status.Cards, CanMeasureUnlockedCard);
        }

        private static bool CanMeasureUnlockedCard(MeasureCard card)
        {
            return card != null && card.CanUnlocked && !card.HasComparisonForBoot && !string.IsNullOrWhiteSpace(card.Bdf);
        }

        private static List<string> GetMeasureTargets(MeasureStatus status, string action, bool automatic, MeasureCard selected)
        {
            var targets = new List<string>();
            if (action == "Unlocked")
            {
                foreach (var card in status.Cards)
                    if ((selected == null || selected == card) && CanMeasureUnlockedCard(card)) targets.Add(card.Bdf);
            }
            else if (automatic)
            {
                foreach (var card in status.Cards)
                    if (card.CanStock && !card.HasStock) targets.Add(card.Bdf);
            }
            else targets.Add(null);
            return targets;
        }

        private void OpenBenchmarks()
        {
            if (busy) return;
            busy = true;
            UpdateButtons();
            try { ShowBenchmarks(drives.SelectedItem as UsbDrive, null, null); }
            finally { busy = false; UpdateButtons(); }
        }

        private MeasureStatus ShowBenchmarks(UsbDrive usb, MeasureStatus initial, string automaticAction)
        {
            using (var dialog = new BenchmarkWindow((action, python, gpu) => RunMeasure(action, python, gpu, usb),
                (step, detail, notify) => OpenDiagnostics(step, detail, usb, true, notify, false),
                EnsureBenchmarkPrerequisite, benchmarkPython, initial, automaticAction))
            {
                dialog.ShowDialog(this);
                benchmarkPython = dialog.PythonSelection;
                return dialog.Measurement;
            }
        }

        private async Task EnsureBenchmarkPrerequisite()
        {
            var result = await RunBackend("FixBenchmarkRuntime", null, null);
            if (result.ExitCode != 0)
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(result.Error)
                    ? "Setup could not verify the Microsoft Visual C++ runtime." : result.Error.Trim());
        }

        private async Task<bool> RunAutomaticBenchmark(string action, UsbDrive usb, bool explicitRetry = false)
        {
            if (!automaticBenchmarks.Checked) return true;
            string failure;
            try
            {
                var status = ParseMeasureStatus(await RunMeasure("Status", benchmarkPython, null, usb));
                if (action == "Stock" && HasStockForAll(status)) return true;
                bool needsRuntime = action == "Stock" && status.CanProvision && string.IsNullOrWhiteSpace(status.Python);
                if ((!needsRuntime && !CanMeasure(status, action, true)) || string.IsNullOrWhiteSpace(status.BootId))
                {
                    if (action == "Stock") Append(status.ProvisionMessage ?? status.Message);
                    else if (!status.HasComparisonForBoot) Append("No unlocked tensor test is ready. Open Tensor benchmarks to see which GPUs still need a matching stock test.");
                    return action != "Stock";
                }
                if (!automaticRuns.Add(action + ":" + status.BootId) && !explicitRetry) return false;
                var measured = ShowBenchmarks(usb, status, action);
                if (action != "Stock") return true;
                if (!HasStockForAll(measured)) return false;
                Append("Stock tensor baselines are saved for the detected GPUs.");
                return true;
            }
            catch (Exception error)
            {
                Append("Automatic tensor test could not start. Open Tensor benchmarks for details. " + error.Message);
                failure = error.Message;
            }
            await OpenDiagnostics("Automatic " + action + " tensor test", failure, usb, explicitRetry, openReport: false);
            return false;
        }

        internal static async Task<bool> ResolveStockBeforeStaging(Func<Task<bool>> tryStock, Func<DialogResult> choose)
        {
            while (!await tryStock())
            {
                var choice = choose();
                if (choice == DialogResult.Ignore) return true;
                if (choice != DialogResult.Retry) return false;
            }
            return true;
        }

        private DialogResult ShowStockBenchmarkOptions()
        {
            using (var dialog = new Form
            {
                Text = "Stock benchmark did not finish", StartPosition = FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi, ClientSize = new Size(620, 190),
                FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false,
                ShowInTaskbar = false, Font = Font, BackColor = Canvas, ForeColor = Ink
            })
            {
                var content = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(18) };
                content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                dialog.Controls.Add(content);
                AddText(content, new Label { Font = new Font("Segoe UI Semibold", 14) },
                    "The read-only test passed", Accent, 37);
                AddText(content, new Label(),
                    "Retry the stock test to get a before-and-after comparison. You can prepare the unlock USB now, but any GPU without a stock result will have no comparison for this attempt.",
                    Ink, 68);
                var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
                var retry = MakeButton("Retry stock test", true);
                var skip = MakeButton("Continue without comparison", false);
                var back = MakeButton("Back to Setup", false);
                retry.DialogResult = DialogResult.Retry;
                skip.DialogResult = DialogResult.Ignore;
                back.DialogResult = DialogResult.Cancel;
                buttons.Controls.AddRange(new Control[] { retry, skip, back });
                content.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                content.Controls.Add(buttons);
                dialog.AcceptButton = retry;
                dialog.CancelButton = back;
                var result = dialog.ShowDialog(this);
                if (result == DialogResult.Ignore)
                    Append("Continuing without a stock comparison for any GPU that does not have a baseline. Automatic benchmarks stay enabled.");
                return result;
            }
        }

        private sealed class BenchmarkWindow : Form
        {
            private readonly Func<string, string, string, Task<BackendResult>> run;
            private readonly Func<string, string, Action<string>, Task> reportFailure;
            private readonly Func<Task> prepareRuntime;
            private readonly string automaticAction;
            private readonly Label statusLabel = new Label();
            private readonly Label pythonLabel = new Label();
            private readonly ListView results = new ListView();
            private readonly TextBox activity = new TextBox();
            private readonly Button stock = MakeButton("Run stock test", true);
            private readonly Button unlocked = MakeButton("Run unlocked test", true);
            private readonly Button setupRuntime = MakeButton("Set up benchmarks", true);
            private readonly Button browse = MakeButton("Choose Python", false);
            private readonly Button refresh = MakeButton("Refresh", false);
            private readonly Button folder = MakeButton("Open results folder", false);
            private readonly Button back = MakeButton("Back to Setup", false);
            private bool working;

            public string PythonSelection { get; private set; }
            public MeasureStatus Measurement { get; private set; }

            public BenchmarkWindow(Func<string, string, string, Task<BackendResult>> run,
                Func<string, string, Action<string>, Task> reportFailure, Func<Task> prepareRuntime, string python,
                MeasureStatus initial, string automaticAction)
            {
                this.run = run;
                this.reportFailure = reportFailure;
                this.prepareRuntime = prepareRuntime;
                this.automaticAction = automaticAction;
                PythonSelection = python;
                Measurement = initial;
                Text = "Tensor benchmarks";
                StartPosition = FormStartPosition.CenterParent;
                AutoScaleMode = AutoScaleMode.Dpi;
                ClientSize = new Size(830, 520);
                MinimumSize = new Size(720, 470);
                BackColor = Canvas;
                ForeColor = Ink;
                Font = new Font("Segoe UI", 10);

                var content = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(18) };
                content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                Controls.Add(content);
                AddText(content, new Label { Font = new Font("Segoe UI Semibold", 15) }, "Tensor throughput", Accent, 34);
                AddText(content, new Label(), "Before unlock: save a stock test from Windows Boot Manager. After a verified unlock boot: keep the USB connected and selected in Setup to run the unlocked test. Use the same Python, driver, power and clock settings.", Ink, 61);
                AddText(content, statusLabel, "Checking benchmark prerequisites...", Warning, 56);
                AddText(content, pythonLabel, "Looking for CUDA-enabled Python...", Muted, 28);

                var controls = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = true };
                var help = MakeButton("Benchmark help", false);
                controls.Controls.AddRange(new Control[] { setupRuntime, stock, unlocked, browse, refresh, folder, help, back });
                back.Click += delegate { Close(); };
                content.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
                content.Controls.Add(controls);
                help.Click += delegate
                {
                    var choice = MessageBox.Show(this, "1. Before unlocking, boot normally through Windows Boot Manager. Use Set up benchmarks if CUDA Python is missing, or click Run stock test.\r\n\r\n" +
                    "2. After the verified unlock boot, reopen Setup with the same USB selected. If the unlocked test does not start automatically, click Run unlocked test. Open the results folder to view the comparison.\r\n\r\n" +
                    "If the benchmark check cannot start, extract the entire ZIP to a fresh local folder. Open Setup from File Explorer using your signed-in account, then click Refresh here.\r\n\r\nOpen the PyTorch guide for using your own Python environment?",
                        "Benchmark help", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                    if (choice == DialogResult.Yes)
                    {
                        try { OpenLink("https://pytorch.org/get-started/locally/"); }
                        catch (Exception error) { AppendActivity(error.Message); }
                    }
                };
                results.Dock = DockStyle.Fill;
                results.View = View.Details;
                results.FullRowSelect = true;
                results.MultiSelect = false;
                results.HideSelection = false;
                results.ShowItemToolTips = true;
                results.AccessibleName = "Per GPU tensor benchmark comparisons";
                results.Columns.Add("GPU", 245);
                results.Columns.Add("PCI address", 125);
                results.Columns.Add("Stock", 75);
                results.Columns.Add("FP16", 71);
                results.Columns.Add("BF16", 71);
                results.Columns.Add("TF32", 71);
                results.Columns.Add("FP32", 71);
                content.RowStyles.Add(new RowStyle(SizeType.Percent, 55));
                content.Controls.Add(results);
                results.SelectedIndexChanged += delegate { UpdateMeasureButtons(); };

                activity.Dock = DockStyle.Fill;
                activity.Multiline = true;
                activity.ReadOnly = true;
                activity.ScrollBars = ScrollBars.Vertical;
                activity.BackColor = PanelColor;
                activity.ForeColor = Ink;
                activity.AccessibleName = "Benchmark activity";
                content.RowStyles.Add(new RowStyle(SizeType.Percent, 45));
                content.Controls.Add(activity);

                stock.Click += async delegate { await RunTest("Stock", false); };
                unlocked.Click += async delegate { await RunTest("Unlocked", false); };
                setupRuntime.Click += async delegate { await SetUpRuntime(false); };
                refresh.Click += async delegate { await Check(); };
                browse.Click += async delegate
                {
                    using (var picker = new OpenFileDialog { Title = "Choose a CUDA-enabled Python interpreter", Filter = "Python interpreter (python.exe)|python.exe", CheckFileExists = true })
                    {
                        if (picker.ShowDialog(this) != DialogResult.OK) return;
                        PythonSelection = picker.FileName;
                    }
                    await Check();
                };
                folder.Click += delegate
                {
                    try { Process.Start(new ProcessStartInfo(Measurement.ResultsDirectory) { UseShellExecute = true }); }
                    catch (Exception error) { AppendActivity(error.Message); }
                };
                FormClosing += delegate(object sender, FormClosingEventArgs e)
                {
                    if (working && e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
                };
                Display();
            }

            protected override async void OnShown(EventArgs e)
            {
                base.OnShown(e);
                if (automaticAction == null) await Check();
                else if (automaticAction == "Stock" && Measurement != null && Measurement.CanProvision && string.IsNullOrWhiteSpace(Measurement.Python))
                    await SetUpRuntime(true);
                else await RunTest(automaticAction, true);
            }

            private void Display()
            {
                var status = Measurement;
                var pending = status == null ? null : Array.Find(status.Cards, card => card != null && !card.HasComparisonForBoot);
                statusLabel.Text = status == null ? "Checking benchmark prerequisites..." :
                    status.HasComparisonForBoot ? "Matched stock and unlocked comparisons are saved. Open the results folder to view the reports." :
                    status.BootConfirmed && pending != null && !CanMeasure(status, "Unlocked", true) ? pending.Message ?? status.Message :
                    status.Message;
                pythonLabel.Text = status == null ? "Looking for CUDA-enabled Python..." :
                    !string.IsNullOrWhiteSpace(status.Python) ? "Python: " + status.Python :
                    status.CanProvision ? "Click Set up benchmarks to install a private benchmark environment." :
                    status.ProvisionMessage ?? "Choose Python to use an existing CUDA PyTorch environment.";
                results.BeginUpdate();
                results.Items.Clear();
                if (status != null)
                {
                    foreach (var card in status.Cards)
                    {
                        var row = new ListViewItem(new[] { card.Label ?? "GPU", card.Bdf ?? "", card.HasStock ? "Saved" : "Needed",
                            Ratio(card, "fp16_fp32_accumulate"), Ratio(card, "bf16_fp32_accumulate"),
                            Ratio(card, "tf32_fp32_accumulate"), Ratio(card, "fp32_ieee") });
                        row.ToolTipText = card.Message ?? "";
                        row.Tag = card;
                        results.Items.Add(row);
                    }
                }
                results.EndUpdate();
                UpdateMeasureButtons();
            }

            private static string Ratio(MeasureCard card, string name)
            {
                MeasureMode mode;
                return card.HasComparisonForBoot && card.Modes != null && card.Modes.TryGetValue(name, out mode) &&
                    mode != null && mode.speed_ratio > 0 && !double.IsInfinity(mode.speed_ratio)
                    ? mode.speed_ratio.ToString("0.00") + "×" : "—";
            }

            private void UpdateMeasureButtons()
            {
                stock.Enabled = !working && CanMeasure(Measurement, "Stock", false);
                var selected = SelectedMeasureCard();
                unlocked.Enabled = !working && (selected == null ? CanMeasure(Measurement, "Unlocked", false) : CanMeasureUnlockedCard(selected));
                unlocked.Text = selected == null ? "Run unlocked test" : "Run unlocked on selected GPU";
                setupRuntime.Enabled = !working && Measurement != null && Measurement.CanProvision;
                browse.Enabled = refresh.Enabled = back.Enabled = !working;
                folder.Enabled = !working && Measurement != null && Directory.Exists(Measurement.ResultsDirectory);
                UseWaitCursor = working;
            }

            private async Task SetUpRuntime(bool automatic)
            {
                if (working || Measurement == null || !Measurement.CanProvision) return;
                if (!automatic && MessageBox.Show(this,
                    "Set up private Python, pip and CUDA PyTorch, then run the stock tensor test? Setup downloads about 2.7 GB and installs the Microsoft Visual C++ runtime if needed. Close GPU-heavy apps and use a normal Windows Boot Manager boot.",
                    Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return;
                working = true;
                UpdateMeasureButtons();
                statusLabel.Text = "Setting up the benchmark environment. Keep this window open during the download and installation.";
                string failure = null;
                try
                {
                    await prepareRuntime();
                    var response = await run("Provision", null, null);
                    AppendActivity(response.Error);
                    var provisioned = ParseMeasureStatus(response);
                    if (string.IsNullOrWhiteSpace(provisioned.Python))
                        throw new InvalidOperationException("Setup could not verify the benchmark Python environment.");
                    PythonSelection = provisioned.Python;
                    Measurement = provisioned;
                    Display();
                }
                catch (Exception error)
                {
                    failure = error.Message;
                    statusLabel.Text = error.Message;
                    AppendActivity(error.Message);
                }
                try { if (failure != null) await reportFailure("Set up tensor benchmarks", failure, AppendActivity); }
                finally { working = false; UpdateMeasureButtons(); }
                if (failure == null) await RunTest("Stock", true);
            }

            private MeasureCard SelectedMeasureCard()
            {
                return results.SelectedItems.Count == 1 ? results.SelectedItems[0].Tag as MeasureCard : null;
            }

            private async Task<MeasureStatus> Read(string action, string gpu)
            {
                var response = await run(action, PythonSelection, gpu);
                if (action != "Status") AppendActivity(response.Error);
                return ParseMeasureStatus(response);
            }

            private async Task Check()
            {
                if (working) return;
                working = true;
                UpdateMeasureButtons();
                statusLabel.Text = "Checking benchmark prerequisites...";
                string failure = null;
                try { Measurement = await Read("Status", null); Display(); }
                catch (Exception error)
                {
                    Measurement = null;
                    Display();
                    statusLabel.Text = error.Message;
                    AppendActivity(error.Message);
                    failure = error.Message;
                }
                try { if (failure != null) await reportFailure("Tensor benchmark check", failure, AppendActivity); }
                finally { working = false; UpdateMeasureButtons(); }
            }

            private async Task RunTest(string action, bool automatic)
            {
                var selected = !automatic && action == "Unlocked" ? SelectedMeasureCard() : null;
                if (working || !CanMeasure(Measurement, action, automatic) || (selected != null && !CanMeasureUnlockedCard(selected))) return;
                var targets = GetMeasureTargets(Measurement, action, automatic, selected);
                if (targets.Count == 0) return;
                if (!automatic)
                {
                    var prompt = action == "Stock"
                        ? "Run the stock tensor test now? Use a stock Windows session started from Windows Boot Manager. Close GPU-heavy apps before continuing."
                        : "Run the unlocked tensor test now? Setup tests the selected GPU or each eligible GPU with a matching stock baseline. Keep the verified unlock USB connected and close other GPU-heavy apps.";
                    if (MessageBox.Show(this, prompt, Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return;
                }
                working = true;
                bool returnToSetup = false;
                string selectedGpu = null;
                string failure = null;
                UpdateMeasureButtons();
                statusLabel.Text = "Running the " + action.ToLowerInvariant() + " tensor test. Keep this window open until it finishes.";
                try
                {
                    foreach (var gpu in targets)
                    {
                        selectedGpu = gpu;
                        var outcome = await Read(action, gpu);
                        AppendActivity(outcome.Message);
                        if (outcome.Status != "Complete") break;
                    }
                    Measurement = await Read("Status", null);
                    Display();
                    returnToSetup = automatic && action == "Stock" && HasStockForAll(Measurement);
                }
                catch (Exception error)
                {
                    statusLabel.Text = error.Message;
                    AppendActivity(error.Message);
                    failure = error.Message;
                }
                try
                {
                    if (failure != null)
                        await reportFailure(action + " tensor test" + (selectedGpu == null ? "" : " on PCI " + selectedGpu),
                            failure, AppendActivity);
                }
                finally { working = false; UpdateMeasureButtons(); }
                if (returnToSetup) Close();
            }

            private void AppendActivity(string message)
            {
                if (string.IsNullOrWhiteSpace(message)) return;
                if (activity.TextLength > 48000) activity.Text = activity.Text.Substring(activity.TextLength - 32000);
                if (message.Length > 16000) message = message.Substring(message.Length - 16000);
                activity.AppendText(message + Environment.NewLine);
            }
        }

        private static string Quote(string value)
        {
            if (value.IndexOf('"') >= 0) throw new ArgumentException("Invalid path.");
            int trailing = value.Length - value.TrimEnd('\\').Length;
            return "\"" + value + new string('\\', trailing) + "\"";
        }

        private void Append(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return;
            if (activity.TextLength > 60000) activity.Text = activity.Text.Substring(activity.TextLength - 40000);
            activity.AppendText(text + Environment.NewLine);
        }

        private void OpenFile(string path)
        {
            try
            {
                if (!File.Exists(path)) throw new FileNotFoundException("That file is not available yet.");
                Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "notepad.exe"), Quote(path)) { UseShellExecute = true });
            }
            catch (Exception error) { MessageBox.Show(this, error.Message, Text); }
        }

        private static void OpenLink(string url)
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            bool resumed;
            try { resumed = Resume.Consume(Application.ExecutablePath, args); }
            catch (Exception error)
            {
                resumed = true;
                MessageBox.Show("Setup could not clear its sign-in shortcut. " + error.Message,
                    "Windows GPU Unlock Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            if (!File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "RTX.ps1")))
            {
                SetupWindow.ShowExtractionSteps(null);
                return;
            }
            bool first;
            using (var instance = new Mutex(true, @"Local\WindowsGpuUnlockSetup", out first))
            {
                if (first) Application.Run(new SetupWindow(Resume.ReadVolume(args)));
                else if (!resumed) MessageBox.Show("Windows GPU Unlock Setup is already running.", "Windows GPU Unlock Setup");
            }
        }
    }
}
