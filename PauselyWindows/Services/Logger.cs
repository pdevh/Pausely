using System;
using System.IO;

namespace PauselyWindows
{
    public static class Logger
    {
        private static readonly string LogDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Pausely", "Logs");
        private static readonly string LogFile = Path.Combine(LogDir, "app.log");
        private static readonly object LockObj = new object();

        static Logger()
        {
            try
            {
                if (!Directory.Exists(LogDir))
                {
                    Directory.CreateDirectory(LogDir);
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [FATAL] Failed to initialize log directory: {ex.Message}");
            }
        }

        public static void Info(string message)
        {
            Log("INFO", message);
        }

        public static void Warn(string message)
        {
            Log("WARN", message);
        }

        public static void Error(string message, Exception? ex = null)
        {
            string detail = ex != null ? $"{message} - Exception: {ex}" : message;
            Log("ERROR", detail);
        }

        public static void Fatal(string message, Exception? ex = null)
        {
            string detail = ex != null ? $"{message} - Exception: {ex}" : message;
            Log("FATAL", detail);
        }

        private static void Log(string level, string message)
        {
            string formattedMessage = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [{level}] {message}";

            // Write to console
            if (level == "ERROR" || level == "FATAL")
            {
                Console.Error.WriteLine(formattedMessage);
            }
            else
            {
                Console.WriteLine(formattedMessage);
            }

            // Write to file
            lock (LockObj)
            {
                try
                {
                    File.AppendAllText(LogFile, formattedMessage + Environment.NewLine);
                }
                catch
                {
                    Console.Error.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [ERROR] Failed to write log to file: {formattedMessage}");
                }
            }
        }
    }
}
