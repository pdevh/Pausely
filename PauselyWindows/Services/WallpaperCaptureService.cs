using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;

namespace PauselyWindows.Services
{
    /// <summary>
    /// Captures the current desktop wallpaper and produces a blurred variant.
    /// Analogous to the macOS RenderedWallpaperProvider.
    /// </summary>
    public class WallpaperCaptureService
    {
        public static WallpaperCaptureService Shared { get; } = new WallpaperCaptureService();

        public ImageSource? CrispWallpaper { get; private set; }
        public ImageSource? BlurredWallpaper { get; private set; }

        private const int SPI_GETDESKWALLPAPER = 0x0073;
        private const int MAX_PATH = 260;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool SystemParametersInfo(int uAction, int uParam, System.Text.StringBuilder lpvParam, int fuWinIni);

        /// <summary>
        /// Refreshes the cached wallpaper images. Call before showing overlays.
        /// </summary>
        public void Refresh()
        {
            try
            {
                var path = GetWallpaperPath();
                if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path))
                {
                    Logger.Warn("WallpaperCaptureService: No wallpaper file found. Using solid black fallback.");
                    CrispWallpaper = null;
                    BlurredWallpaper = null;
                    return;
                }

                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.UriSource = new Uri(path, UriKind.Absolute);
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.EndInit();
                bitmap.Freeze();

                CrispWallpaper = bitmap;
                BlurredWallpaper = CreateBlurredCopy(bitmap, 24.0);

                Logger.Info($"WallpaperCaptureService: Loaded wallpaper from {path}");
            }
            catch (Exception ex)
            {
                Logger.Warn($"WallpaperCaptureService: Failed to load wallpaper. Exception: {ex.Message}");
                CrispWallpaper = null;
                BlurredWallpaper = null;
            }
        }

        private static string? GetWallpaperPath()
        {
            var sb = new System.Text.StringBuilder(MAX_PATH);
            SystemParametersInfo(SPI_GETDESKWALLPAPER, MAX_PATH, sb, 0);
            return sb.ToString();
        }

        /// <summary>
        /// Renders the source image with a BlurEffect into a new frozen BitmapSource.
        /// </summary>
        private static BitmapSource CreateBlurredCopy(BitmapSource source, double blurRadius)
        {
            // Render at a reduced resolution for performance, then the Image control will stretch it
            double scale = Math.Min(1.0, 1920.0 / source.PixelWidth);
            int renderWidth = (int)(source.PixelWidth * scale);
            int renderHeight = (int)(source.PixelHeight * scale);

            var image = new System.Windows.Controls.Image
            {
                Source = source,
                Width = renderWidth,
                Height = renderHeight,
                Stretch = Stretch.Fill,
                Effect = new BlurEffect { Radius = blurRadius * scale, KernelType = KernelType.Gaussian }
            };

            image.Measure(new System.Windows.Size(renderWidth, renderHeight));
            image.Arrange(new Rect(0, 0, renderWidth, renderHeight));
            image.UpdateLayout();

            var rtb = new RenderTargetBitmap(renderWidth, renderHeight, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(image);
            rtb.Freeze();

            return rtb;
        }
    }
}
