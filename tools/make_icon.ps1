param(
    [string]$InputPath = "assets/Haatiloggofull.jpg",
    [string]$OutPng    = "EditorIcon.png",
    [string]$OutIco    = "haati/editor/haati.ico"
)

$ErrorActionPreference = "Stop"

$src = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class HaatiIconBuilder
{
    public static void Build(string inputPath, string outPngPath, string outIcoPath)
    {
        using (var rawImg = new Bitmap(inputPath))
        {
            int w = rawImg.Width;
            int h = rawImg.Height;
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.DrawImage(rawImg, 0, 0, w, h);
                }

                var rect = new Rectangle(0, 0, w, h);
                var data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
                int stride = data.Stride;
                byte[] pixels = new byte[stride * h];
                Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);

                // Exterior-only BFS flood fill starting from image border where max(R,G,B) <= 8.
                bool[] visited = new bool[w * h];
                int[] queue = new int[w * h];
                int qHead = 0, qTail = 0;

                Action<int, int> tryEnqueue = (x, y) =>
                {
                    int idx = y * w + x;
                    if (visited[idx]) return;
                    int p = y * stride + x * 4;
                    byte b = pixels[p + 0];
                    byte g = pixels[p + 1];
                    byte r = pixels[p + 2];
                    byte maxCh = Math.Max(r, Math.Max(g, b));
                    if (maxCh <= 8)
                    {
                        visited[idx] = true;
                        queue[qTail++] = idx;
                    }
                };

                for (int x = 0; x < w; x++)
                {
                    tryEnqueue(x, 0);
                    tryEnqueue(x, h - 1);
                }
                for (int y = 1; y < h - 1; y++)
                {
                    tryEnqueue(0, y);
                    tryEnqueue(w - 1, y);
                }

                while (qHead < qTail)
                {
                    int cur = queue[qHead++];
                    int cx = cur % w;
                    int cy = cur / w;
                    if (cx > 0)     tryEnqueue(cx - 1, cy);
                    if (cx < w - 1) tryEnqueue(cx + 1, cy);
                    if (cy > 0)     tryEnqueue(cx, cy - 1);
                    if (cy < h - 1) tryEnqueue(cx, cy + 1);
                }

                // Clear exterior pixels to full transparency.
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++)
                    {
                        if (!visited[y * w + x]) continue;
                        int p = y * stride + x * 4;
                        pixels[p + 0] = 0;
                        pixels[p + 1] = 0;
                        pixels[p + 2] = 0;
                        pixels[p + 3] = 0;
                    }
                }

                // Anti-aliased transition fringe within 2 pixels of exterior background.
                byte[] dist = new byte[w * h];
                for (int pass = 1; pass <= 2; pass++)
                {
                    for (int y = 0; y < h; y++)
                    {
                        for (int x = 0; x < w; x++)
                        {
                            int idx = y * w + x;
                            if (visited[idx] || dist[idx] != 0) continue;
                            bool near = false;
                            for (int dy = -1; dy <= 1 && !near; dy++)
                            {
                                int ny = y + dy;
                                if (ny < 0 || ny >= h) continue;
                                for (int dx = -1; dx <= 1; dx++)
                                {
                                    int nx = x + dx;
                                    if (nx < 0 || nx >= w) continue;
                                    int nidx = ny * w + nx;
                                    if (pass == 1 ? visited[nidx] : (dist[nidx] == 1))
                                    {
                                        near = true;
                                        break;
                                    }
                                }
                            }
                            if (near) dist[idx] = (byte)pass;
                        }
                    }
                }

                int minX = w, minY = h, maxX = -1, maxY = -1;
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++)
                    {
                        int idx = y * w + x;
                        int p = y * stride + x * 4;
                        if (dist[idx] != 0)
                        {
                            byte b = pixels[p + 0];
                            byte g = pixels[p + 1];
                            byte r = pixels[p + 2];
                            byte maxCh = Math.Max(r, Math.Max(g, b));
                            if (maxCh < 28)
                            {
                                int a = (maxCh - 4) * 255 / 24;
                                if (a < 0) a = 0;
                                if (a > 255) a = 255;
                                pixels[p + 3] = (byte)a;
                            }
                        }
                        if (pixels[p + 3] > 16)
                        {
                            if (x < minX) minX = x;
                            if (x > maxX) maxX = x;
                            if (y < minY) minY = y;
                            if (y > maxY) maxY = y;
                        }
                    }
                }

                Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
                bmp.UnlockBits(data);

                if (maxX < minX || maxY < minY)
                {
                    minX = 0; minY = 0; maxX = w - 1; maxY = h - 1;
                }

                double centerX = (minX + maxX) * 0.5;
                double centerY = (minY + maxY) * 0.5;
                int span = Math.Max(maxX - minX + 1, maxY - minY + 1);
                int side = (int)Math.Ceiling(span * 1.03);
                if (side < 1) side = Math.Max(w, h);

                int offsetX = (int)Math.Round(side * 0.5 - centerX);
                int offsetY = (int)Math.Round(side * 0.5 - centerY);

                using (var square = new Bitmap(side, side, PixelFormat.Format32bppArgb))
                {
                    using (var g = Graphics.FromImage(square))
                    {
                        g.Clear(Color.Transparent);
                        g.CompositingMode = CompositingMode.SourceOver;
                        g.DrawImageUnscaled(bmp, offsetX, offsetY);
                    }

                    EnsureParentDir(outPngPath);
                    using (var png512 = ResizeSquare(square, 512))
                    {
                        png512.Save(outPngPath, ImageFormat.Png);
                    }

                    int[] sizes = new int[] { 16, 32, 48, 64, 128, 256 };
                    byte[][] frames = new byte[sizes.Length][];
                    for (int i = 0; i < sizes.Length; i++)
                    {
                        using (var frameBmp = ResizeSquare(square, sizes[i]))
                        using (var ms = new MemoryStream())
                        {
                            frameBmp.Save(ms, ImageFormat.Png);
                            frames[i] = ms.ToArray();
                        }
                    }

                    EnsureParentDir(outIcoPath);
                    using (var fs = new FileStream(outIcoPath, FileMode.Create, FileAccess.Write))
                    using (var bw = new BinaryWriter(fs))
                    {
                        bw.Write((ushort)0);               // Reserved
                        bw.Write((ushort)1);               // Type: ICON
                        bw.Write((ushort)sizes.Length);    // Count

                        uint offset = (uint)(6 + 16 * sizes.Length);
                        for (int i = 0; i < sizes.Length; i++)
                        {
                            int s = sizes[i];
                            byte wh = (s >= 256) ? (byte)0 : (byte)s;
                            bw.Write(wh);                  // bWidth
                            bw.Write(wh);                  // bHeight
                            bw.Write((byte)0);             // bColorCount
                            bw.Write((byte)0);             // bReserved
                            bw.Write((ushort)1);           // wPlanes
                            bw.Write((ushort)32);          // wBitCount
                            bw.Write((uint)frames[i].Length); // dwBytesInRes
                            bw.Write(offset);              // dwImageOffset
                            offset += (uint)frames[i].Length;
                        }
                        for (int i = 0; i < frames.Length; i++)
                        {
                            bw.Write(frames[i]);
                        }
                    }
                }
            }
        }
    }

    private static Bitmap ResizeSquare(Bitmap square, int size)
    {
        var dst = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        dst.SetResolution(96, 96);
        using (var g = Graphics.FromImage(dst))
        using (var ia = new ImageAttributes())
        {
            ia.SetWrapMode(WrapMode.TileFlipXY);
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.DrawImage(
                square,
                new Rectangle(0, 0, size, size),
                0, 0, square.Width, square.Height,
                GraphicsUnit.Pixel,
                ia
            );
        }
        return dst;
    }

    private static void EnsureParentDir(string path)
    {
        string dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }
    }
}
"@

Add-Type -TypeDefinition $src -ReferencedAssemblies @("System.Drawing.dll")

$absIn  = [System.IO.Path]::GetFullPath($InputPath)
$absPng = [System.IO.Path]::GetFullPath($OutPng)
$absIco = [System.IO.Path]::GetFullPath($OutIco)

[HaatiIconBuilder]::Build($absIn, $absPng, $absIco)
Write-Host ("Generated PNG: {0} ({1} bytes)" -f $OutPng, (Get-Item $absPng).Length)
Write-Host ("Generated ICO: {0} ({1} bytes)" -f $OutIco, (Get-Item $absIco).Length)
