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
[assembly: System.Reflection.AssemblyVersion("0.4.0.6")]

namespace RtxSetup
{
    internal sealed class Card
    {
        public string Label { get; set; }
        public string Bdf { get; set; }
        public string Device { get; set; }
        public int MemoryMiB { get; set; }
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
        public bool HasComparisonForBoot { get; set; }
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
        private readonly Button format = MakeButton("Format USB", false);
        private readonly Button offline = MakeButton("Offline inputs", false);
        private readonly Button bootLog = MakeButton("Open USB log", false);
        private readonly Button benchmark = MakeButton("Tensor benchmarks", false);
        private const string ResumeOptionText = "Reopen Setup at next sign-in after a setup change";
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
            Text = "Run tensor benchmarks automatically", Dock = DockStyle.Fill, ForeColor = Muted
        };
        private readonly HashSet<string> automaticRuns = new HashSet<string>(StringComparer.Ordinal);
        private string benchmarkPython;
        private const string RecoverySteps = "Fully power off, remove the USB, then start Windows Boot Manager directly. " +
            "After Windows returns, reconnect the USB and save its boot log before restoring the probe if you need the log.";
        private KitStatus state;
        private bool busy;
        private string inputCache;
        private string nextAction;
        private string requestedVolume;

        public SetupWindow(string resumeVolume)
        {
            requestedVolume = resumeVolume;
            Text = "Windows GPU Unlock Setup";
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
            masthead.Controls.Add(new Label { Text = "RTX 30 and 40 series  /  One or two cards  /  Preview 0.4 build 6", ForeColor = Accent, Location = new Point(2, 52), AutoSize = true });
            frame.Controls.Add(masthead, 0, 0);
            frame.SetColumnSpan(masthead, 2);

            var rail = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, BackColor = PanelColor, Padding = new Padding(16), Margin = new Padding(0, 0, 16, 0) };
            rail.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            frame.Controls.Add(rail, 0, 1);
            AddRail(rail, "SETUP PATH", Accent, 31);
            AddRail(rail, "01   Check this PC", Ink, 37);
            AddRail(rail, "02   Prepare probe USB", Ink, 37);
            AddRail(rail, "03   Test boot from USB", Ink, 37);
            AddRail(rail, "04   Stage and boot unlock", Ink, 37);
            AddRail(rail, "05   Verify each GPU", Ink, 37);
            AddRail(rail, "Use the USB for each boot you want unlocked.", Muted, 55);
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
            actions.Controls.AddRange(new Control[] { primary, refresh, restore, format, benchmark, offline, bootLog });
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
                if (nextAction == "Help") await RefreshHelp(ShowBootHelp);
                else if (nextAction == "BiosHelp") await RefreshHelp(ShowBiosHelp);
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
            format.Click += async delegate { await RunFlow("FormatUsb"); };
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
            offline.Enabled = !busy;
            benchmark.Enabled = !busy;
            reopen.Enabled = !busy && !resumeDisarmed;
            automaticBenchmarks.Enabled = !busy;
            restore.Visible = state != null && state.HasPackage &&
                (state.MediaState == "Recoverable" || state.MediaState == "UnlockStaged" || state.MediaState == "UnlockLogged");
            restore.Enabled = !busy;
            format.Visible = CanFormatBlockedFat32(state, FindFormatDrive(state, drives.SelectedItem as UsbDrive), KitTargetListMissing);
            format.Enabled = !busy;
            bootLog.Enabled = !busy && state != null && state.HasLog;
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
                if (eligible == null || (eligible.FileSystem == "FAT32" && !CanFormatBlockedFat32(state, eligible, KitTargetListMissing)))
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
            if (action != null)
            {
                if (!windowsAction && (usb == null || string.IsNullOrEmpty(usb.VolumeId))) return;
                if (!ConfirmAction(action, usb)) return;
            }
            busy = true;
            UpdateButtons();
            try
            {
                bool completed = false;
                if (action != null)
                {
                    if (action == "StageUnlock" && !await RunAutomaticBenchmark("Stock", usb, true))
                    {
                        next.Text = "A stock result is still missing. Open Tensor benchmarks to retry or turn off automatic tensor benchmarks to stage without a baseline.";
                        Append(next.Text);
                        return;
                    }
                    Append("Running " + action + (windowsAction ? " in Windows." : " on " + letter + ":"));
                    var result = await RunBackend(action, windowsAction ? null : letter, windowsAction ? null : usb.VolumeId);
                    completed = result.ExitCode == 0;
                    if (!completed) Append("Operation stopped. Review the activity above.");
                }
                state = await ReadStatus(letter);
                bool justFormatted = completed && action == "FormatUsb";
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
                ShowStatus(selection);
                UpdateResumeAfterFlow(action, completed);
                if (completed && (windowsAction || action == "FormatUsb" ||
                    ((action == "Prepare" || action == "RestoreProbe") && state.MediaState == "ProbeStaged") ||
                    (action == "StageUnlock" && state.CanBootUnlock))) ArmResume();
                var benchmarkUsb = drives.SelectedItem as UsbDrive;
                if (completed && action == "Prepare" && state.MediaState == "ProbeStaged")
                    await RunAutomaticBenchmark("Stock", benchmarkUsb);
                else if (checkAutomaticUnlocked && benchmarkUsb != null && state.MediaState == "UnlockLogged" &&
                    HasVerifiedBootPrerequisites(state))
                    await RunAutomaticBenchmark("Unlocked", benchmarkUsb);
            }
            catch (Exception error)
            {
                state = null;
                nextAction = null;
                phase.Text = "Setup check failed";
                next.Text = error.Message;
                Append(error.Message);
            }
            finally
            {
                busy = false;
                UpdateButtons();
            }
        }

        private bool ConfirmAction(string action, UsbDrive usb)
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
                    prompt = string.Format("Erase every file on USB {0}: ({1}, {2}, {3:0.0} GB) and format it as FAT32? Check the letter and back up its files before continuing.",
                        usb.Letter, string.IsNullOrWhiteSpace(usb.Label) ? "unnamed drive" : usb.Label, usb.DiskModel, usb.TotalBytes / 1e9);
                    break;
                case "Prepare":
                    prompt = "Prepare the read-only probe on " + usb + "? Use a dedicated, backed-up USB drive.";
                    if (automaticBenchmarks.Checked)
                        prompt += "\r\n\r\nIf a stock baseline is needed, Setup will then run a tensor test that loads the GPUs. For stock measurements, start Windows Boot Manager directly after a full shutdown. Close games and other GPU-heavy apps before continuing.";
                    break;
                case "StageUnlock":
                    prompt = "Did the USB probe return to Windows on its own? If it did, click OK to stage the unlock on " + usb +
                        ". At the next USB boot, Space or Enter confirms the unlock for the listed GPUs.";
                    if (automaticBenchmarks.Checked)
                        prompt += "\r\n\r\nSetup will run any missing stock tensor tests before staging. If a baseline is missing, fully shut down, start Windows Boot Manager directly, and return to Setup. Close other GPU-heavy apps before the test.";
                    break;
                default:
                    prompt = "Restore the verified read-only probe on " + usb + "? This clears the old USB boot log. Save a copy first if you need it.";
                    break;
            }
            bool sensitive = action == "FormatUsb" || action == "DisableEncryption";
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

        private static bool HasVerifiedBootPrerequisites(KitStatus status)
        {
            return IsFullyDecrypted(status) && status.FirmwareState == "Ready" && status.FastStartupState == "Disabled" &&
                status.BootProblems != null && status.BootProblems.Length == 0 &&
                status.WindowsDisplayProblems != null && status.WindowsDisplayProblems.Length == 0 &&
                string.IsNullOrWhiteSpace(status.InventoryError) && string.IsNullOrWhiteSpace(status.PackageError) &&
                string.IsNullOrWhiteSpace(status.StorageError);
        }

        private async Task<KitStatus> ReadStatus(string letter)
        {
            var result = await RunBackend("Status", letter, null);
            if (result.ExitCode != 0) throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(result.Error) ? "Setup check exited with code " + result.ExitCode : result.Error.Trim());
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
                hardware.Add(string.Format("{0}   {1:0.##} GB   PCI {2}   ID {3}", card.Label, card.MemoryMiB / 1024.0, card.Bdf, card.Device));
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
                    phase.Text = "Boot the read-only probe";
                    nextAction = "Help";
                    break;
                case "ProbePassed":
                    phase.Text = "Probe passed";
                    next.Text = blockers.Count == 0
                        ? "The read-only test matched every card and started Windows handoff. If Windows opened on its own, click Stage unlock USB."
                        : "The probe passed. Complete the Windows checks above before staging the unlock.";
                    if (blockers.Count == 0) nextAction = "StageUnlock";
                    break;
                case "UnlockStaged":
                    phase.Text = "Unlock loader staged";
                    nextAction = "Help";
                    break;
                case "UnlockLogged":
                    phase.Text = "Latest USB boot log";
                    break;
                case "Recoverable":
                    phase.Text = "Restore the probe to resume";
                    break;
                case "Blocked":
                    phase.Text = "USB needs attention";
                    break;
            }
            if (!string.IsNullOrWhiteSpace(state.MediaTitle)) phase.Text = state.MediaTitle;
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
            if (canConfigure && eligibleFormat != null && eligibleFormat.FileSystem != "FAT32")
            {
                phase.Text = "Format this USB as FAT32";
                next.Text = "This USB needs FAT32. Back up its files, then click Format USB. Setup will check the drive again afterward.";
                nextAction = "FormatUsb";
            }
            if (canConfigure && state.CanFixFastStartup)
            {
                phase.Text = "Turn off Fast Startup";
                next.Text = "Click Turn off Fast Startup. Setup will change the Windows setting and verify it.";
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
            if (nextAction == "FixFastStartup") primary.Text = "Turn off Fast Startup";
            else if (nextAction == "DisableEncryption") primary.Text = "Turn off BitLocker";
            else if (nextAction == "BiosHelp") primary.Text = "Show BIOS steps";
            else if (nextAction == "FormatUsb") primary.Text = "Format USB";
            else if (nextAction == "Prepare") primary.Text = "Prepare probe USB";
            else if (nextAction == "StageUnlock") primary.Text = "Stage unlock USB";
            else if (nextAction == "Help")
            {
                if (available.Count == 0) primary.Text = "USB drive help";
                else primary.Text = (state.MediaState == "UnlockStaged" && !state.CanBootUnlock) || !HasVerifiedBootPrerequisites(state)
                    ? "Show recovery steps" : "Show boot steps";
            }
            else if (selected == null) primary.Text = "Select a USB drive";
            else primary.Text = "Setup action unavailable";
            foreach (string blocker in blockers) Append(blocker);
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
                : "The read-only probe can wait 30 seconds at its prompt. Let it run and return to Windows.";
            string boot = "1. Save your work and shut down Windows completely.\r\n\r\n" +
                "2. Turn the PC on. Use the one-time Boot Menu key shown by your PC at startup, then choose " + entry + ".\r\n\r\n" +
                "3. " + step + " Once Windows returns, reopen Setup and click Refresh.";
            if (probeStaged && state.HasLog) boot = next.Text + "\r\n\r\nIf you run the read-only test again:\r\n\r\n" + boot;
            MessageBox.Show(this,
                boot + "\r\n\r\n" + recovery,
                "Boot and recovery help", MessageBoxButtons.OK, MessageBoxIcon.Information);
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
                reopen.Text = "Unlock boot verified. Automatic reopening is off.";
                Append("This unlock boot is verified. Setup's one-time reopen entry is cleared.");
            }
            catch (Exception error)
            {
                reopen.Text = "Unlock boot verified. Refresh to retry removing the reopen entry.";
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
                Quote(Path.Combine(root, "RTX.ps1")) + " -Desktop -Action " + action;
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
                        if (action == "Status") stderr.AppendLine(e.Data);
                        else BeginInvoke(new Action<string>(Append), e.Data);
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
                if (report != null && report.Cards != null) return report;
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
                benchmarkPython, initial, automaticAction))
            {
                dialog.ShowDialog(this);
                benchmarkPython = dialog.PythonSelection;
                return dialog.Measurement;
            }
        }

        private async Task<bool> RunAutomaticBenchmark(string action, UsbDrive usb, bool explicitRetry = false)
        {
            if (!automaticBenchmarks.Checked) return true;
            try
            {
                var status = ParseMeasureStatus(await RunMeasure("Status", benchmarkPython, null, usb));
                if (action == "Stock" && HasStockForAll(status)) return true;
                if (!CanMeasure(status, action, true) || string.IsNullOrWhiteSpace(status.BootId))
                {
                    if (action == "Stock" && !string.IsNullOrWhiteSpace(status.Message)) Append(status.Message);
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
                return false;
            }
        }

        private sealed class BenchmarkWindow : Form
        {
            private readonly Func<string, string, string, Task<BackendResult>> run;
            private readonly string automaticAction;
            private readonly Label statusLabel = new Label();
            private readonly Label pythonLabel = new Label();
            private readonly ListView results = new ListView();
            private readonly TextBox activity = new TextBox();
            private readonly Button stock = MakeButton("Run stock test", true);
            private readonly Button unlocked = MakeButton("Run unlocked test", true);
            private readonly Button browse = MakeButton("Choose Python", false);
            private readonly Button refresh = MakeButton("Refresh", false);
            private readonly Button folder = MakeButton("Open results folder", false);
            private bool working;

            public string PythonSelection { get; private set; }
            public MeasureStatus Measurement { get; private set; }

            public BenchmarkWindow(Func<string, string, string, Task<BackendResult>> run, string python,
                MeasureStatus initial, string automaticAction)
            {
                this.run = run;
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
                AddText(content, new Label(), "For a stock baseline, start Windows Boot Manager directly. After an unlock boot, keep that USB connected and selected in Setup. Keep the driver, power limit and clock settings the same. Select a GPU row to run its unlocked test separately.", Ink, 61);
                AddText(content, statusLabel, "Checking benchmark prerequisites...", Warning, 56);
                AddText(content, pythonLabel, "Looking for CUDA-enabled Python...", Muted, 28);

                var controls = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = true };
                var help = MakeButton("Python help", false);
                controls.Controls.AddRange(new Control[] { stock, unlocked, browse, refresh, folder, help });
                content.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
                content.Controls.Add(controls);
                help.Click += delegate
                {
                    var choice = MessageBox.Show(this, "Choose python.exe from a Windows environment with CUDA-enabled PyTorch. If you use Forge or ComfyUI, try its Python environment. Use the same interpreter for both runs.\r\n\r\nOpen the PyTorch setup guide?",
                        "Benchmark Python help", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
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
                else await RunTest(automaticAction, true);
            }

            private void Display()
            {
                var status = Measurement;
                statusLabel.Text = status == null ? "Checking benchmark prerequisites..." : status.Message;
                pythonLabel.Text = status == null || string.IsNullOrWhiteSpace(status.Python)
                    ? "Choose a Python environment with CUDA-enabled PyTorch if automatic detection fails."
                    : "Python: " + status.Python;
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
                browse.Enabled = refresh.Enabled = !working;
                folder.Enabled = !working && Measurement != null && Directory.Exists(Measurement.ResultsDirectory);
                UseWaitCursor = working;
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
                try { Measurement = await Read("Status", null); Display(); }
                catch (Exception error) { Measurement = null; Display(); statusLabel.Text = error.Message; AppendActivity(error.Message); }
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
                UpdateMeasureButtons();
                statusLabel.Text = "Running the " + action.ToLowerInvariant() + " tensor test. Keep this window open until it finishes.";
                try
                {
                    foreach (var gpu in targets)
                    {
                        var outcome = await Read(action, gpu);
                        AppendActivity(outcome.Message);
                        if (outcome.Status != "Complete") break;
                    }
                    Measurement = await Read("Status", null);
                    Display();
                    returnToSetup = automatic && action == "Stock" && HasStockForAll(Measurement);
                }
                catch (Exception error) { statusLabel.Text = error.Message; AppendActivity(error.Message); }
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
            if (!File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "RTX.ps1")))
            {
                MessageBox.Show("Right-click the downloaded ZIP and choose Extract All. Open Windows GPU Unlock Setup.exe from the extracted folder.",
                    "Extract the whole ZIP first", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            bool first;
            using (var instance = new Mutex(true, @"Local\WindowsGpuUnlockSetup", out first))
            {
                if (first) Application.Run(new SetupWindow(Resume.ReadVolume(args)));
                else MessageBox.Show("Windows GPU Unlock Setup is already running.", "Windows GPU Unlock Setup");
            }
        }
    }
}
