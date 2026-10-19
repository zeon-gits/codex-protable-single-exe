// C# 5 / .NET Framework 4.x; no third-party dependencies.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

internal static class Launcher
{
    private const string Magic = "CGPTPORTABLE0001"; // 16 ASCII bytes
    private const int FooterSize = 64; // offset:int64, length:int64, sha256:32, magic:16

    private static int Main(string[] args)
    {
        // Opt into modern .NET Framework path handling without a sidecar .config file.
        AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling", false);
        AppContext.SetSwitch("Switch.System.IO.BlockLongPaths", false);
        bool test = args.Length > 0;
        try
        {
            if (args.Length > 0 && args[0] != "--verify-payload" && args[0] != "--extract-only")
                throw new ArgumentException("Usage: [--verify-payload | --extract-only NEW_DIRECTORY]");
            if ((args.Length > 0 && args[0] == "--verify-payload" && args.Length != 1) ||
                (args.Length > 0 && args[0] == "--extract-only" && args.Length != 2))
                throw new ArgumentException("Invalid command line.");

            string self = Assembly.GetExecutingAssembly().Location;
            using (FileStream file = new FileStream(self, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (file.Length < FooterSize) throw new InvalidDataException("Payload footer missing.");
                file.Position = file.Length - FooterSize;
                BinaryReader reader = new BinaryReader(file);
                long offset = reader.ReadInt64();
                long length = reader.ReadInt64();
                byte[] expected = reader.ReadBytes(32);
                if (Encoding.ASCII.GetString(reader.ReadBytes(16)) != Magic || offset < 1 || length < 1 ||
                    offset > file.Length - FooterSize || length != file.Length - FooterSize - offset)
                    throw new InvalidDataException("Invalid or truncated payload.");

                using (SliceStream payload = new SliceStream(file, offset, length))
                {
                    Console.WriteLine("Verifying embedded MSIX...");
                    byte[] actual;
                    using (SHA256 sha = SHA256.Create()) actual = sha.ComputeHash(payload);
                    if (BitConverter.ToString(actual) != BitConverter.ToString(expected))
                        throw new InvalidDataException("Embedded MSIX checksum mismatch.");
                    string hash = BitConverter.ToString(actual).Replace("-", "").ToLowerInvariant();
                    payload.Position = 0;
                    using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read, true))
                    {
                        if (archive.GetEntry("app/ChatGPT.exe") == null || archive.GetEntry("AppxManifest.xml") == null)
                            throw new InvalidDataException("Expected ChatGPT MSIX layout not found.");
                        if (args.Length > 0 && args[0] == "--verify-payload")
                        {
                            Console.WriteLine("Payload OK: " + hash);
                            return 0;
                        }
                        if (args.Length > 0 && args[0] == "--extract-only")
                        {
                            string output = Path.GetFullPath(args[1]);
                            if (Directory.Exists(output) || File.Exists(output))
                                throw new IOException("Extraction target must not already exist.");
                            Extract(archive, output);
                            Console.WriteLine("Extracted to " + output);
                            return 0;
                        }

                        string data = Path.Combine(Path.GetDirectoryName(self), "ChatGPTPortableData");
                        Directory.CreateDirectory(data);
                        // Exclusive lock prevents simultaneous extraction/launch by this wrapper.
                        using (FileStream gate = new FileStream(Path.Combine(data, "launcher.lock"),
                            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
                        {
                            string runtimeRoot = Path.Combine(data, "runtime");
                            Directory.CreateDirectory(runtimeRoot);
                            string runtime = Path.Combine(runtimeRoot, hash);
                            string marker = Path.Combine(runtime, ".complete");
                            if (!File.Exists(marker))
                            {
                                if (Directory.Exists(runtime))
                                    throw new IOException("Incomplete runtime exists. Close all app processes and remove: " + runtime);
                                string stage = Path.Combine(runtimeRoot, ".extract-" + Guid.NewGuid().ToString("N"));
                                try
                                {
                                    Console.WriteLine("Extracting application (first start can take several minutes)...");
                                    Extract(archive, stage);
                                    File.WriteAllText(Path.Combine(stage, ".complete"), hash);
                                    Directory.Move(stage, runtime);
                                }
                                finally
                                {
                                    if (Directory.Exists(stage)) Directory.Delete(stage, true);
                                }
                            }
                            string profile = Path.Combine(data, "profile");
                            string codex = Path.Combine(data, "codex");
                            Directory.CreateDirectory(profile);
                            Directory.CreateDirectory(codex);
                            string executable = Path.Combine(runtime, "app", "ChatGPT.exe");
                            if (!File.Exists(executable)) throw new FileNotFoundException("Cached executable missing.", executable);
                            ProcessStartInfo start = new ProcessStartInfo(executable);
                            start.WorkingDirectory = Path.GetDirectoryName(executable);
                            start.UseShellExecute = false;
                            start.Arguments = "--user-data-dir=" + Quote(profile);
                            start.EnvironmentVariables["CODEX_HOME"] = codex;
                            File.AppendAllText(Path.Combine(data, "launcher.log"),
                                DateTime.UtcNow.ToString("o") + " Starting MSIX " + hash + Environment.NewLine);
                            Console.WriteLine("Starting experimental unpackaged application. Keep this window open.");
                            Console.WriteLine("No MSIX registration or Windows service installation is performed.");
                            using (Process process = Process.Start(start))
                            {
                                process.WaitForExit();
                                int code = process.ExitCode;
                                File.AppendAllText(Path.Combine(data, "launcher.log"),
                                    DateTime.UtcNow.ToString("o") + " Main process exit: " + code + Environment.NewLine);
                                // Keep runtime cache: Electron/background processes can outlive the main process.
                                if (code != 0) throw new IOException("Application exited with code " + code);
                            }
                        }
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            if (!test && !Console.IsInputRedirected)
            {
                Console.Error.WriteLine("Press Enter to close. Copy this error for troubleshooting.");
                Console.ReadLine();
            }
            return 1;
        }
    }

    private static string Quote(string s)
    {
        // Paths cannot contain quotes. Directory name has no trailing backslash.
        if (s.IndexOf('"') >= 0 || s.EndsWith("\\", StringComparison.Ordinal))
            throw new ArgumentException("Unsupported profile path.");
        return "\"" + s + "\"";
    }

    private static void Extract(ZipArchive archive, string destination)
    {
        Directory.CreateDirectory(destination);
        string root = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        // Extended-length paths work without changing the machine-wide long-path policy.
        if (!root.StartsWith(@"\\?\", StringComparison.Ordinal))
            root = root.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + root.Substring(2) : @"\\?\" + root;
        foreach (ZipArchiveEntry entry in archive.Entries)
        {
            if (!entry.FullName.StartsWith("app/", StringComparison.Ordinal)) continue;
            string name = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
            if (name.IndexOf(':') >= 0) throw new InvalidDataException("Unsafe archive path.");
            string target = Path.GetFullPath(Path.Combine(root, name));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Archive path escapes destination.");
            if (entry.FullName.EndsWith("/", StringComparison.Ordinal))
            {
                Directory.CreateDirectory(target);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            using (Stream input = entry.Open())
            using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write))
                input.CopyTo(output);
        }
    }

    // Expose the appended original ZIP as a zero-based seekable stream.
    private sealed class SliceStream : Stream
    {
        private readonly Stream source;
        private readonly long offset;
        private readonly long length;
        private long position;
        public SliceStream(Stream source, long offset, long length)
        { this.source = source; this.offset = offset; this.length = length; }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return length; } }
        public override long Position
        {
            get { return position; }
            set { Seek(value, SeekOrigin.Begin); }
        }
        public override long Seek(long value, SeekOrigin origin)
        {
            long next = checked((origin == SeekOrigin.Begin ? 0 : origin == SeekOrigin.Current ? position : length) + value);
            if (next < 0 || next > length) throw new IOException("Seek outside payload.");
            position = next;
            return position;
        }
        public override int Read(byte[] buffer, int start, int count)
        {
            source.Position = offset + position;
            int read = source.Read(buffer, start, (int)Math.Min((long)count, length - position));
            position += read;
            return read;
        }
        public override void Flush() { }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int start, int count) { throw new NotSupportedException(); }
        // Deliberately leave the owning file stream open.
    }
}
