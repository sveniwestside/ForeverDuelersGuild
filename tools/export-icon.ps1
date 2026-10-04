# Convert the generated PNG master into a power-of-two WoW texture.
# This is a format/size export only; the artwork is generated with Imagegen.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$fdRoot = Split-Path -Parent $PSScriptRoot
$fdSource = [System.Drawing.Image]::FromFile((Join-Path $fdRoot 'assets/branding/foreverduel-icon.png'))
$fdBitmap = [System.Drawing.Bitmap]::new(128, 128, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$fdGraphics = [System.Drawing.Graphics]::FromImage($fdBitmap)
try {
    $fdGraphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $fdGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $fdGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $fdGraphics.DrawImage($fdSource, 0, 0, 128, 128)
    $fdBitmap.Save((Join-Path $fdRoot 'assets/branding/foreverduel-icon-128.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    # Uncompressed true-color TGA: BGRA pixels, top-left origin, 8 alpha bits.
    $fdBytes = [byte[]]::new(18 + 128 * 128 * 4)
    $fdBytes[2] = 2
    $fdBytes[12] = 128
    $fdBytes[14] = 128
    $fdBytes[16] = 32
    $fdBytes[17] = 40
    $fdOffset = 18
    for ($fdY = 0; $fdY -lt 128; $fdY++) {
        for ($fdX = 0; $fdX -lt 128; $fdX++) {
            $fdPixel = $fdBitmap.GetPixel($fdX, $fdY)
            $fdBytes[$fdOffset++] = $fdPixel.B
            $fdBytes[$fdOffset++] = $fdPixel.G
            $fdBytes[$fdOffset++] = $fdPixel.R
            $fdBytes[$fdOffset++] = $fdPixel.A
        }
    }
    [System.IO.File]::WriteAllBytes((Join-Path $fdRoot 'ForeverDuel/Media/Icon.tga'), $fdBytes)
    Write-Output 'Exported 128x128 RGBA PNG and uncompressed 32-bit TGA with alpha.'
} finally {
    $fdGraphics.Dispose()
    $fdBitmap.Dispose()
    $fdSource.Dispose()
}
