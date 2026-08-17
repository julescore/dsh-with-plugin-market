using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DeepSeekHarnessDesktop;

internal static class Program
{
    internal const string ProductName = "DeepSeek Harness";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--self-test")
        {
            try
            {
                var resources = HarnessResources.Load();
                var result = new
                {
                    product = ProductName,
                    node = File.Exists(resources.Node),
                    launcher = File.Exists(resources.Launcher),
                    visionPatch = File.Exists(resources.VisionPatch),
                    marketPatch = File.Exists(resources.MarketPatch),
                    marketConflictPatch = File.Exists(resources.MarketConflictPatch),
                    recoveryScript = File.Exists(resources.RecoveryScript),
                    diagnosisScript = File.Exists(resources.DiagnosisScript),
                    conflictParser = HarnessConfig.ContainsMarketEntry("- id: dsh-market\n  name: dshmarket\n"),
                };
                File.WriteAllText(args[1], JsonSerializer.Serialize(result));
                return 0;
            }
            catch (Exception error)
            {
                File.WriteAllText(args[1], JsonSerializer.Serialize(new { error = error.Message }));
                return 1;
            }
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
        return 0;
    }
}

internal sealed record HarnessResources(
    string Root,
    string Node,
    string Launcher,
    string VisionPatch,
    string MarketPatch,
    string MarketConflictPatch,
    string RecoveryScript,
    string DiagnosisScript)
{
    internal static HarnessResources Load()
    {
        var root = AppContext.BaseDirectory;
        var resources = new HarnessResources(
            root,
            Path.Combine(root, "node", "node.exe"),
            Path.Combine(root, "runtime", "lib", "bin.js"),
            Path.Combine(root, "desktop", "vision.patch.yml"),
            Path.Combine(root, "desktop", "market.patch.yml"),
            Path.Combine(root, "desktop", "market-conflict.patch.yml"),
            Path.Combine(root, "desktop", "reset-web-profile.mjs"),
            Path.Combine(root, "desktop", "diagnose-web-plugins.mjs"));
        foreach (var path in new[] { resources.Node, resources.Launcher, resources.VisionPatch, resources.MarketPatch, resources.MarketConflictPatch, resources.RecoveryScript, resources.DiagnosisScript })
        {
            if (!File.Exists(path)) throw new FileNotFoundException($"Required application resource is missing: {path}", path);
        }
        return resources;
    }

    internal ProcessStartInfo CreateStartInfo(IEnumerable<string> arguments, bool redirect = true, bool redirectInput = false)
    {
        var info = new ProcessStartInfo(Node)
        {
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = redirect,
            RedirectStandardError = redirect,
            RedirectStandardInput = redirectInput,
        };
        info.Environment["PATH"] = Path.Combine(Root, "node") + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH");
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        return info;
    }
}

internal sealed record ProfileRecoveryResult(bool Changed, string? Profile, string? Backup);

internal static class ProfileRecovery
{
    internal static async Task<ProfileRecoveryResult> ResetAsync(HarnessResources resources)
    {
        using var process = new Process
        {
            StartInfo = resources.CreateStartInfo(new[] { resources.RecoveryScript }),
        };
        process.Start();
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Unable to back up and reset the local Web profile (exit {process.ExitCode}).\n\n{error.Trim()}");
        }
        return JsonSerializer.Deserialize<ProfileRecoveryResult>(output, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        }) ?? throw new InvalidOperationException("The local recovery tool returned an invalid result.");
    }
}

internal sealed record PluginCandidate(string Name, string Spec, string[] Signals);

internal sealed record WebPluginDiagnosis(bool ProfileExists, bool ManifestValid, PluginCandidate[] Candidates);

internal static class PluginDiagnostics
{
    private static string Tail(string value, int maximumBytes)
    {
        return value.Length <= maximumBytes ? value : value[^maximumBytes..];
    }

    internal static async Task<WebPluginDiagnosis> DiagnoseAsync(HarnessResources resources, string failure)
    {
        using var process = new Process
        {
            StartInfo = resources.CreateStartInfo(new[] { resources.DiagnosisScript }, redirectInput: true),
        };
        process.Start();
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        await process.StandardInput.WriteAsync(failure);
        process.StandardInput.Close();
        var exitTask = process.WaitForExitAsync();
        try
        {
            await exitTask.WaitAsync(TimeSpan.FromSeconds(30));
        }
        catch (TimeoutException)
        {
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            await exitTask;
            _ = await outputTask;
            _ = await errorTask;
            throw new TimeoutException("The startup diagnosis timed out.");
        }
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Unable to diagnose the startup failure (exit {process.ExitCode}).\n\n{Tail(error.Trim(), 32_768)}");
        }
        return JsonSerializer.Deserialize<WebPluginDiagnosis>(output, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        }) ?? throw new InvalidOperationException("The startup diagnosis returned an invalid result.");
    }

    internal static async Task UninstallWebPluginsAsync(HarnessResources resources, IReadOnlyList<string> names)
    {
        var arguments = new List<string> { resources.Launcher, "plugin", "--profile", "web", "remove" };
        arguments.AddRange(names);
        using var process = new Process
        {
            StartInfo = resources.CreateStartInfo(arguments),
        };
        process.Start();
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        var exitTask = process.WaitForExitAsync();
        try
        {
            await exitTask.WaitAsync(TimeSpan.FromMinutes(5));
        }
        catch (TimeoutException)
        {
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            await exitTask;
            _ = await outputTask;
            _ = await errorTask;
            throw new TimeoutException($"Uninstalling the incompatible plugin(s) ({string.Join(", ", names)}) timed out.");
        }
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            var detail = string.IsNullOrWhiteSpace(error) ? output : error;
            throw new InvalidOperationException($"Unable to uninstall the incompatible plugin(s) ({string.Join(", ", names)}) (exit {process.ExitCode}).\n\n{Tail(detail.Trim(), 32_768)}");
        }
    }
}

internal static class HarnessConfig
{
    internal static bool ContainsMarketEntry(string config)
    {
        foreach (var sourceLine in config.Split('\n'))
        {
            var line = sourceLine.Trim();
            if (!line.StartsWith("- id:", StringComparison.Ordinal)) continue;
            var value = line[5..].Trim().Trim('\'', '"');
            if (value == "dsh-market") return true;
        }
        return false;
    }

    internal static async Task<bool> DetectsLocalMarketAsync(HarnessResources resources)
    {
        using var process = new Process
        {
            StartInfo = resources.CreateStartInfo(new[] { resources.Launcher, "web", "--dump-config" }),
        };
        process.Start();
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Unable to inspect the local plugin configuration (exit {process.ExitCode}).\n\n{error.Trim()}");
        }
        return ContainsMarketEntry(output);
    }
}

internal enum MarketLaunchMode
{
    Local,
    Bundled,
    BundledReplacingLocal,
}

internal sealed class MainForm : Form
{
    private readonly Label status = new()
    {
        Dock = DockStyle.Fill,
        Text = "Starting DeepSeek Harness…\r\n\r\nThe first launch may take a few seconds.",
        TextAlign = ContentAlignment.MiddleCenter,
        Font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 15, FontStyle.Regular),
    };
    private readonly StringBuilder errorTail = new();
    private Process? harness;
    private HarnessResources? resources;
    private Uri? harnessOrigin;
    private bool stopping;
    private bool recovering;
    private bool started;
    private bool exitRequested;
    private volatile bool harnessReady;
    private MarketLaunchMode? lastMarketChoice;
    private bool? lastHadLocalMarket;
    private PluginCandidate[] pendingUninstall = Array.Empty<PluginCandidate>();
    private NotifyIcon? trayIcon;
    private Icon? trayIconImage;

    internal MainForm()
    {
        Text = Program.ProductName;
        MinimumSize = new Size(900, 620);
        Size = new Size(1280, 820);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(status);
        InstallTrayIcon();
        Shown += async (_, _) =>
        {
            if (started) return;
            started = true;
            await StartAsync();
        };
        FormClosing += (_, eventArgs) =>
        {
            if (eventArgs.CloseReason == CloseReason.UserClosing && !exitRequested)
            {
                eventArgs.Cancel = true;
                Hide();
                ShowInTaskbar = false;
                return;
            }
            StopHarness();
        };
        Application.ApplicationExit += (_, _) =>
        {
            trayIcon?.Dispose();
            trayIconImage?.Dispose();
        };
    }

    private void InstallTrayIcon()
    {
        trayIconImage = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        var icon = trayIconImage ?? SystemIcons.Application;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open DeepSeek Harness", null, (_, _) => ShowMainWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit DeepSeek Harness", null, (_, _) => ExitApplication());
        trayIcon = new NotifyIcon
        {
            Icon = icon,
            Text = Program.ProductName,
            ContextMenuStrip = menu,
            Visible = true,
        };
        trayIcon.Click += (_, _) => ShowMainWindow();
    }

    private void ShowMainWindow()
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(ShowMainWindow));
            return;
        }
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        ShowInTaskbar = true;
        Activate();
    }

    private void ExitApplication()
    {
        exitRequested = true;
        Application.Exit();
    }

    private async Task StartAsync()
    {
        try
        {
            resources = HarnessResources.Load();
            await StartHarnessAsync(resources);
        }
        catch (Exception error)
        {
            await ShowStartupFailureAsync(error.Message);
        }
    }

    private async Task StartHarnessAsync(HarnessResources loaded)
    {
        var hasLocalMarket = await HarnessConfig.DetectsLocalMarketAsync(loaded);
        var hadLocalMarket = lastHadLocalMarket ?? false;
        var mode = MarketLaunchMode.Bundled;
        if (hasLocalMarket)
        {
            if (lastMarketChoice is MarketLaunchMode previous && hadLocalMarket)
            {
                mode = previous;
            }
            else
            {
                var choice = MessageBox.Show(
                    this,
                    "The local Web profile and this installer both contain a plugin market. Only one can be active at a time.\n\nYes: use the local plugin market\nNo: use the market bundled with this installer\nCancel: exit\n\nOther plugins, sessions, and credentials will not be deleted or reset.",
                    "Plugin market conflict",
                    MessageBoxButtons.YesNoCancel,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button1);
                if (choice == DialogResult.Cancel)
                {
                    ExitApplication();
                    return;
                }
                mode = choice == DialogResult.Yes ? MarketLaunchMode.Local : MarketLaunchMode.BundledReplacingLocal;
                lastMarketChoice = mode;
            }
        }
        else
        {
            lastMarketChoice = null;
        }
        lastHadLocalMarket = hasLocalMarket;
        StartHarness(loaded, mode);
    }

    private void StartHarness(HarnessResources loaded, MarketLaunchMode mode)
    {
        harnessOrigin = null;
        harnessReady = false;
        lock (errorTail) errorTail.Clear();
        var arguments = new List<string> { loaded.Launcher, "web", "--patch", loaded.VisionPatch };
        if (mode == MarketLaunchMode.Bundled) arguments.AddRange(new[] { "--patch", loaded.MarketPatch });
        if (mode == MarketLaunchMode.BundledReplacingLocal) arguments.AddRange(new[] { "--patch", loaded.MarketConflictPatch });
        arguments.AddRange(new[] { "--port", "0" });
        var process = new Process { StartInfo = loaded.CreateStartInfo(arguments), EnableRaisingEvents = true };
        harness = process;
        process.OutputDataReceived += (_, eventArgs) =>
        {
            if (stopping || eventArgs.Data is null || !eventArgs.Data.StartsWith("dsh web: ", StringComparison.Ordinal)) return;
            var candidate = eventArgs.Data[9..].Split(' ', 2)[0];
            if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)
                || uri.Scheme != Uri.UriSchemeHttp || uri.Host != "127.0.0.1") return;
            harnessReady = true;
            BeginInvoke(new Action(async () => await OpenWebViewAsync(uri)));
        };
        process.ErrorDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null) return;
            lock (errorTail)
            {
                errorTail.AppendLine(eventArgs.Data);
                if (errorTail.Length > 32_768) errorTail.Remove(0, errorTail.Length - 32_768);
            }
        };
        process.Exited += (_, _) =>
        {
            if (stopping || recovering) return;
            var wasReady = harnessReady;
            var exitCode = process.ExitCode;
            string detail;
            lock (errorTail) detail = errorTail.ToString().Trim();
            BeginInvoke(new Action(() =>
            {
                var message = wasReady
                    ? $"The Harness background process exited unexpectedly (exit {exitCode})."
                    : $"The Harness startup failed (exit {exitCode}).";
                if (detail.Length > 0) message += $"\r\n\r\n{detail}";
                if (wasReady)
                {
                    ShowFailure(message);
                }
                else
                {
                    _ = ShowStartupFailureAsync(message);
                }
            }));
        };
        recovering = false;
        if (!process.Start()) throw new InvalidOperationException("Unable to start the bundled DeepSeek Harness runtime.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    private async Task OpenWebViewAsync(Uri uri)
    {
        if (stopping || harnessOrigin is not null) return;
        harnessOrigin = new Uri(uri.GetLeftPart(UriPartial.Authority));
        var view = new WebView2 { Dock = DockStyle.Fill };
        Controls.Clear();
        Controls.Add(view);
        try
        {
            await view.EnsureCoreWebView2Async();
        }
        catch (WebView2RuntimeNotFoundException)
        {
            ShowFailure("Microsoft Edge WebView2 Runtime is required. Install WebView2 Runtime, then reopen DeepSeek Harness.");
            return;
        }
        catch (Exception error)
        {
            ShowFailure($"The embedded browser could not start.\r\n\r\n{error.Message}");
            return;
        }
        view.CoreWebView2.NewWindowRequested += (_, eventArgs) =>
        {
            eventArgs.Handled = true;
            OpenExternal(eventArgs.Uri);
        };
        view.CoreWebView2.NavigationStarting += (_, eventArgs) =>
        {
            if (!Uri.TryCreate(eventArgs.Uri, UriKind.Absolute, out var target)) return;
            if (target.Scheme is "about" or "blob" || target.GetLeftPart(UriPartial.Authority) == harnessOrigin.GetLeftPart(UriPartial.Authority)) return;
            if (target.Scheme is "http" or "https") OpenExternal(target.AbsoluteUri);
            eventArgs.Cancel = true;
        };
        view.Source = uri;
    }

    private static void OpenExternal(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return;
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }

    private async Task ShowStartupFailureAsync(string message)
    {
        PluginCandidate[] candidates = Array.Empty<PluginCandidate>();
        if (resources is not null)
        {
            try
            {
                candidates = (await PluginDiagnostics.DiagnoseAsync(resources, message)).Candidates;
            }
            catch
            {
                // A diagnosis failure only hides the uninstall actions; the original startup error stays fully visible.
            }
        }
        pendingUninstall = candidates;
        var title = candidates.Length == 0
            ? "Unable to start DeepSeek Harness"
            : "Incompatible plugins detected during startup";
        var body = candidates.Length == 0
            ? message
            : $"The following installed plugin(s) are incompatible with this DeepSeek Harness build and prevented startup:\r\n{string.Join(", ", candidates.Select(candidate => candidate.Name))}\r\n\r\nUninstalling them and restarting preserves sessions, settings, and credentials.\r\n\r\nFailure details:\r\n{message}";
        ShowStartupFailurePanel(title, body, candidates);
    }

    private void ShowStartupFailurePanel(string title, string body, IReadOnlyList<PluginCandidate> candidates)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => ShowStartupFailurePanel(title, body, candidates)));
            return;
        }
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2 + candidates.Count,
            Padding = new Padding(60),
        };
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        status.Text = $"{title}\r\n\r\n{body}";
        panel.Controls.Add(status, 0, 0);
        var row = 1;
        if (candidates.Count > 0)
        {
            var names = candidates.Select(candidate => candidate.Name).ToArray();
            var uninstall = CreateActionButton(
                names.Length == 1 ? $"Uninstall {names[0]} and restart" : "Uninstall incompatible plugins and restart");
            uninstall.Click += async (_, _) => await UninstallIncompatibleAsync(uninstall);
            panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            panel.Controls.Add(uninstall, 0, row++);
        }
        var recover = CreateActionButton("Back up and reset Web profile, then reopen");
        recover.Click += async (_, _) => await RecoverAsync(recover);
        panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        panel.Controls.Add(recover, 0, row);
        Controls.Clear();
        Controls.Add(panel);
    }

    private static Button CreateActionButton(string text)
    {
        return new Button
        {
            Text = text,
            AutoSize = true,
            Anchor = AnchorStyles.None,
            Padding = new Padding(12, 6, 12, 6),
        };
    }

    private void ShowFailure(string message)
    {
        pendingUninstall = Array.Empty<PluginCandidate>();
        ShowStartupFailurePanel("Unable to start DeepSeek Harness", message, Array.Empty<PluginCandidate>());
    }

    private async Task UninstallIncompatibleAsync(Button button)
    {
        if (resources is null || pendingUninstall.Length == 0) return;
        button.Enabled = false;
        var names = pendingUninstall.Select(candidate => candidate.Name).ToArray();
        status.Text = $"Uninstalling incompatible plugin(s)…\r\n\r\n{string.Join(", ", names)}";
        try
        {
            recovering = true;
            StopHarness(forExit: false);
            await PluginDiagnostics.UninstallWebPluginsAsync(resources, names);
            pendingUninstall = Array.Empty<PluginCandidate>();
            harnessOrigin = null;
            status.Text = "Incompatible plugin(s) uninstalled. Restarting DeepSeek Harness…";
            await StartHarnessAsync(resources);
        }
        catch (Exception error)
        {
            recovering = false;
            ShowFailure(error.Message);
        }
    }

    private async Task RecoverAsync(Button button)
    {
        if (resources is null) return;
        button.Enabled = false;
        status.Text = "Recovering the local environment…\r\n\r\nThe Web profile will be backed up first. Sessions, settings, credentials, and personal presets are preserved.";
        try
        {
            recovering = true;
            StopHarness(forExit: false);
            var result = await ProfileRecovery.ResetAsync(resources);
            pendingUninstall = Array.Empty<PluginCandidate>();
            lastMarketChoice = null;
            lastHadLocalMarket = null;
            harnessOrigin = null;
            status.Text = result.Backup is null
                ? "No existing Web profile needed a backup. Restarting DeepSeek Harness…"
                : $"The old Web profile was backed up to:\r\n{result.Backup}\r\n\r\nRestarting DeepSeek Harness…";
            await StartHarnessAsync(resources);
        }
        catch (Exception error)
        {
            recovering = false;
            ShowFailure(error.Message);
        }
    }

    private void StopHarness(bool forExit = true)
    {
        if (forExit) stopping = true;
        if (harness is null) return;
        try
        {
            if (harness.HasExited) return;
            harness.Kill(entireProcessTree: true);
            harness.WaitForExit(5_000);
        }
        catch (InvalidOperationException)
        {
            // The process exited between the state check and termination request.
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // The process exited or was killed between the state check and termination request.
        }
    }
}
