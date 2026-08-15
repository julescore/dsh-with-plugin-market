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
                    marketPatch = File.Exists(resources.MarketPatch),
                    marketConflictPatch = File.Exists(resources.MarketConflictPatch),
                    recoveryScript = File.Exists(resources.RecoveryScript),
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
    string MarketPatch,
    string MarketConflictPatch,
    string RecoveryScript)
{
    internal static HarnessResources Load()
    {
        var root = AppContext.BaseDirectory;
        var resources = new HarnessResources(
            root,
            Path.Combine(root, "node", "node.exe"),
            Path.Combine(root, "runtime", "lib", "bin.js"),
            Path.Combine(root, "desktop", "market.patch.yml"),
            Path.Combine(root, "desktop", "market-conflict.patch.yml"),
            Path.Combine(root, "desktop", "reset-web-profile.mjs"));
        foreach (var path in new[] { resources.Node, resources.Launcher, resources.MarketPatch, resources.MarketConflictPatch, resources.RecoveryScript })
        {
            if (!File.Exists(path)) throw new FileNotFoundException($"Required application resource is missing: {path}", path);
        }
        return resources;
    }

    internal ProcessStartInfo CreateStartInfo(IEnumerable<string> arguments, bool redirect = true)
    {
        var info = new ProcessStartInfo(Node)
        {
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = redirect,
            RedirectStandardError = redirect,
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

    internal MainForm()
    {
        Text = Program.ProductName;
        MinimumSize = new Size(900, 620);
        Size = new Size(1280, 820);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(status);
        Shown += async (_, _) => await StartAsync();
        FormClosing += (_, _) => StopHarness();
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
            ShowFailure(error.Message);
        }
    }

    private async Task StartHarnessAsync(HarnessResources loaded)
    {
        var mode = MarketLaunchMode.Bundled;
        if (await HarnessConfig.DetectsLocalMarketAsync(loaded))
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
                Close();
                return;
            }
            mode = choice == DialogResult.Yes ? MarketLaunchMode.Local : MarketLaunchMode.BundledReplacingLocal;
        }
        StartHarness(loaded, mode);
    }

    private void StartHarness(HarnessResources loaded, MarketLaunchMode mode)
    {
        harnessOrigin = null;
        lock (errorTail) errorTail.Clear();
        var arguments = new List<string> { loaded.Launcher, "web" };
        if (mode == MarketLaunchMode.Bundled) arguments.AddRange(new[] { "--patch", loaded.MarketPatch });
        if (mode == MarketLaunchMode.BundledReplacingLocal) arguments.AddRange(new[] { "--patch", loaded.MarketConflictPatch });
        arguments.AddRange(new[] { "--port", "0" });
        harness = new Process { StartInfo = loaded.CreateStartInfo(arguments), EnableRaisingEvents = true };
        harness.OutputDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null || !eventArgs.Data.StartsWith("dsh web: ", StringComparison.Ordinal)) return;
            var candidate = eventArgs.Data[9..].Split(' ', 2)[0];
            if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)
                || uri.Scheme != Uri.UriSchemeHttp || uri.Host != "127.0.0.1") return;
            BeginInvoke(new Action(async () => await OpenWebViewAsync(uri)));
        };
        harness.ErrorDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null) return;
            lock (errorTail)
            {
                errorTail.AppendLine(eventArgs.Data);
                if (errorTail.Length > 32_768) errorTail.Remove(0, errorTail.Length - 32_768);
            }
        };
        harness.Exited += (_, _) =>
        {
            if (stopping || recovering) return;
            string detail;
            lock (errorTail) detail = errorTail.ToString().Trim();
            BeginInvoke(new Action(() => ShowFailure($"The Harness background process exited unexpectedly (exit {harness.ExitCode})." + (detail.Length == 0 ? "" : $"\r\n\r\n{detail}"))));
        };
        if (!harness.Start()) throw new InvalidOperationException("Unable to start the bundled DeepSeek Harness runtime.");
        recovering = false;
        harness.BeginOutputReadLine();
        harness.BeginErrorReadLine();
    }

    private async Task OpenWebViewAsync(Uri uri)
    {
        if (harnessOrigin is not null) return;
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

    private void ShowFailure(string message)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => ShowFailure(message)));
            return;
        }
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(60),
        };
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        status.Text = $"Unable to start DeepSeek Harness\r\n\r\n{message}";
        var recover = new Button
        {
            Text = "Back up and reset Web profile, then reopen",
            AutoSize = true,
            Anchor = AnchorStyles.None,
            Padding = new Padding(12, 6, 12, 6),
        };
        recover.Click += async (_, _) => await RecoverAsync(recover);
        panel.Controls.Add(status, 0, 0);
        panel.Controls.Add(recover, 0, 1);
        Controls.Clear();
        Controls.Add(panel);
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
        if (harness is null || harness.HasExited) return;
        try
        {
            harness.Kill(entireProcessTree: true);
            harness.WaitForExit(5_000);
        }
        catch (InvalidOperationException)
        {
            // The process exited between the state check and termination request.
        }
    }
}
