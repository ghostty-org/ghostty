const c = @import("c.zig").c;

pub const PixelFormat = enum(c_int) {
    /// 1 bit indexed
    @"1Monochrome" = c.kCVPixelFormatType_1Monochrome,
    /// 2 bit indexed
    @"2Indexed" = c.kCVPixelFormatType_2Indexed,
    /// 4 bit indexed
    @"4Indexed" = c.kCVPixelFormatType_4Indexed,
    /// 8 bit indexed
    @"8Indexed" = c.kCVPixelFormatType_8Indexed,
    /// 1 bit indexed gray, white is zero
    @"1IndexedGray_WhiteIsZero" = c.kCVPixelFormatType_1IndexedGray_WhiteIsZero,
    /// 2 bit indexed gray, white is zero
    @"2IndexedGray_WhiteIsZero" = c.kCVPixelFormatType_2IndexedGray_WhiteIsZero,
    /// 4 bit indexed gray, white is zero
    @"4IndexedGray_WhiteIsZero" = c.kCVPixelFormatType_4IndexedGray_WhiteIsZero,
    /// 8 bit indexed gray, white is zero
    @"8IndexedGray_WhiteIsZero" = c.kCVPixelFormatType_8IndexedGray_WhiteIsZero,
    /// 16 bit BE RGB 555
    @"16BE555" = c.kCVPixelFormatType_16BE555,
    /// 16 bit LE RGB 555
    @"16LE555" = c.kCVPixelFormatType_16LE555,
    /// 16 bit LE RGB 5551
    @"16LE5551" = c.kCVPixelFormatType_16LE5551,
    /// 16 bit BE RGB 565
    @"16BE565" = c.kCVPixelFormatType_16BE565,
    /// 16 bit LE RGB 565
    @"16LE565" = c.kCVPixelFormatType_16LE565,
    /// 24 bit RGB
    @"24RGB" = c.kCVPixelFormatType_24RGB,
    /// 24 bit BGR
    @"24BGR" = c.kCVPixelFormatType_24BGR,
    /// 32 bit ARGB
    @"32ARGB" = c.kCVPixelFormatType_32ARGB,
    /// 32 bit BGRA
    @"32BGRA" = c.kCVPixelFormatType_32BGRA,
    /// 32 bit ABGR
    @"32ABGR" = c.kCVPixelFormatType_32ABGR,
    /// 32 bit RGBA
    @"32RGBA" = c.kCVPixelFormatType_32RGBA,
    /// 64 bit ARGB, 16-bit big-endian samples
    @"64ARGB" = c.kCVPixelFormatType_64ARGB,
    /// 64 bit RGBA, 16-bit little-endian full-range (0-65535) samples
    @"64RGBALE" = c.kCVPixelFormatType_64RGBALE,
    /// 48 bit RGB, 16-bit big-endian samples
    @"48RGB" = c.kCVPixelFormatType_48RGB,
    /// 32 bit AlphaGray, 16-bit big-endian samples, black is zero
    @"32AlphaGray" = c.kCVPixelFormatType_32AlphaGray,
    /// 16 bit Grayscale, 16-bit big-endian samples, black is zero
    @"16Gray" = c.kCVPixelFormatType_16Gray,
    /// 30 bit RGB, 10-bit big-endian samples, 2 unused padding bits (at least significant end).
    @"30RGB" = c.kCVPixelFormatType_30RGB,
    /// 30 bit RGB, 10-bit big-endian samples, 2 unused padding bits (at most significant end), video-range (64-940).
    @"30RGB_r210" = c.kCVPixelFormatType_30RGB_r210,
    /// Component Y'CbCr 8-bit 4:2:2, ordered Cb Y'0 Cr Y'1
    @"422YpCbCr8" = c.kCVPixelFormatType_422YpCbCr8,
    /// Component Y'CbCrA 8-bit 4:4:4:4, ordered Cb Y' Cr A
    @"4444YpCbCrA8" = c.kCVPixelFormatType_4444YpCbCrA8,
    /// Component Y'CbCrA 8-bit 4:4:4:4, rendering format. full range alpha, zero biased YUV, ordered A Y' Cb Cr
    @"4444YpCbCrA8R" = c.kCVPixelFormatType_4444YpCbCrA8R,
    /// Component Y'CbCrA 8-bit 4:4:4:4, ordered A Y' Cb Cr, full range alpha, video range Y'CbCr.
    @"4444AYpCbCr8" = c.kCVPixelFormatType_4444AYpCbCr8,
    /// Component Y'CbCrA 16-bit 4:4:4:4, ordered A Y' Cb Cr, full range alpha, video range Y'CbCr, 16-bit little-endian samples.
    @"4444AYpCbCr16" = c.kCVPixelFormatType_4444AYpCbCr16,
    /// Component AY'CbCr single precision floating-point 4:4:4:4
    @"4444AYpCbCrFloat" = c.kCVPixelFormatType_4444AYpCbCrFloat,
    /// Component Y'CbCr 8-bit 4:4:4, ordered Cr Y' Cb, video range Y'CbCr
    @"444YpCbCr8" = c.kCVPixelFormatType_444YpCbCr8,
    /// Component Y'CbCr 10,12,14,16-bit 4:2:2
    @"422YpCbCr16" = c.kCVPixelFormatType_422YpCbCr16,
    /// Component Y'CbCr 10-bit 4:2:2
    @"422YpCbCr10" = c.kCVPixelFormatType_422YpCbCr10,
    /// Component Y'CbCr 10-bit 4:4:4
    @"444YpCbCr10" = c.kCVPixelFormatType_444YpCbCr10,
    /// Planar Component Y'CbCr 8-bit 4:2:0.  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrPlanar struct
    @"420YpCbCr8Planar" = c.kCVPixelFormatType_420YpCbCr8Planar,
    /// Planar Component Y'CbCr 8-bit 4:2:0, full range.  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrPlanar struct
    @"420YpCbCr8PlanarFullRange" = c.kCVPixelFormatType_420YpCbCr8PlanarFullRange,
    /// First plane: Video-range Component Y'CbCr 8-bit 4:2:2, ordered Cb Y'0 Cr Y'1; second plane: alpha 8-bit 0-255
    @"422YpCbCr_4A_8BiPlanar" = c.kCVPixelFormatType_422YpCbCr_4A_8BiPlanar,
    /// Bi-Planar Component Y'CbCr 8-bit 4:2:0, video-range (luma=[16,235] chroma=[16,240]).  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
    @"420YpCbCr8BiPlanarVideoRange" = c.kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    /// Bi-Planar Component Y'CbCr 8-bit 4:2:0, full-range (luma=[0,255] chroma=[1,255]).  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
    @"420YpCbCr8BiPlanarFullRange" = c.kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    /// Bi-Planar Component Y'CbCr 8-bit 4:2:2, video-range (luma=[16,235] chroma=[16,240]).  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
    @"422YpCbCr8BiPlanarVideoRange" = c.kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
    /// Bi-Planar Component Y'CbCr 8-bit 4:2:2, full-range (luma=[0,255] chroma=[1,255]).  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
    @"422YpCbCr8BiPlanarFullRange" = c.kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
    /// Bi-Planar Component Y'CbCr 8-bit 4:4:4, video-range (luma=[16,235] chroma=[16,240]).  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
    @"444YpCbCr8BiPlanarVideoRange" = c.kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
    /// Bi-Planar Component Y'CbCr 8-bit 4:4:4, full-range (luma=[0,255] chroma=[1,255]).  baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
    @"444YpCbCr8BiPlanarFullRange" = c.kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
    /// Component Y'CbCr 8-bit 4:2:2, ordered Y'0 Cb Y'1 Cr
    @"422YpCbCr8_yuvs" = c.kCVPixelFormatType_422YpCbCr8_yuvs,
    /// Component Y'CbCr 8-bit 4:2:2, full range, ordered Y'0 Cb Y'1 Cr
    @"422YpCbCr8FullRange" = c.kCVPixelFormatType_422YpCbCr8FullRange,
    /// 8 bit one component, black is zero
    OneComponent8 = c.kCVPixelFormatType_OneComponent8,
    /// 8 bit two component, black is zero
    TwoComponent8 = c.kCVPixelFormatType_TwoComponent8,
    /// little-endian RGB101010, 2 MSB are ignored, wide-gamut (384-895)
    @"30RGBLEPackedWideGamut" = c.kCVPixelFormatType_30RGBLEPackedWideGamut,
    /// little-endian ARGB2101010 full-range ARGB
    ARGB2101010LEPacked = c.kCVPixelFormatType_ARGB2101010LEPacked,
    /// little-endian ARGB10101010, each 10 bits in the MSBs of 16bits, wide-gamut (384-895, including alpha)
    @"40ARGBLEWideGamut" = c.kCVPixelFormatType_40ARGBLEWideGamut,
    /// little-endian ARGB10101010, each 10 bits in the MSBs of 16bits, wide-gamut (384-895, including alpha). Alpha premultiplied
    @"40ARGBLEWideGamutPremultiplied" = c.kCVPixelFormatType_40ARGBLEWideGamutPremultiplied,
    /// 10 bit little-endian one component, stored as 10 MSBs of 16 bits, black is zero
    OneComponent10 = c.kCVPixelFormatType_OneComponent10,
    /// 12 bit little-endian one component, stored as 12 MSBs of 16 bits, black is zero
    OneComponent12 = c.kCVPixelFormatType_OneComponent12,
    /// 16 bit little-endian one component, black is zero
    OneComponent16 = c.kCVPixelFormatType_OneComponent16,
    /// 16 bit little-endian two component, black is zero
    TwoComponent16 = c.kCVPixelFormatType_TwoComponent16,
    /// 16 bit one component IEEE half-precision float, 16-bit little-endian samples
    OneComponent16Half = c.kCVPixelFormatType_OneComponent16Half,
    /// 32 bit one component IEEE float, 32-bit little-endian samples
    OneComponent32Float = c.kCVPixelFormatType_OneComponent32Float,
    /// 16 bit two component IEEE half-precision float, 16-bit little-endian samples
    TwoComponent16Half = c.kCVPixelFormatType_TwoComponent16Half,
    /// 32 bit two component IEEE float, 32-bit little-endian samples
    TwoComponent32Float = c.kCVPixelFormatType_TwoComponent32Float,
    /// 64 bit RGBA IEEE half-precision float, 16-bit little-endian samples
    @"64RGBAHalf" = c.kCVPixelFormatType_64RGBAHalf,
    /// 128 bit RGBA IEEE float, 32-bit little-endian samples
    @"128RGBAFloat" = c.kCVPixelFormatType_128RGBAFloat,
    /// Bayer 14-bit Little-Endian, packed in 16-bits, ordered G R G R... alternating with B G B G...
    @"14Bayer_GRBG" = c.kCVPixelFormatType_14Bayer_GRBG,
    /// Bayer 14-bit Little-Endian, packed in 16-bits, ordered R G R G... alternating with G B G B...
    @"14Bayer_RGGB" = c.kCVPixelFormatType_14Bayer_RGGB,
    /// Bayer 14-bit Little-Endian, packed in 16-bits, ordered B G B G... alternating with G R G R...
    @"14Bayer_BGGR" = c.kCVPixelFormatType_14Bayer_BGGR,
    /// Bayer 14-bit Little-Endian, packed in 16-bits, ordered G B G B... alternating with R G R G...
    @"14Bayer_GBRG" = c.kCVPixelFormatType_14Bayer_GBRG,
    /// IEEE754-2008 binary16 (half float), describing the normalized shift when comparing two images. Units are 1/meters: ( pixelShift / (pixelFocalLength * baselineInMeters) )
    DisparityFloat16 = c.kCVPixelFormatType_DisparityFloat16,
    /// IEEE754-2008 binary32 float, describing the normalized shift when comparing two images. Units are 1/meters: ( pixelShift / (pixelFocalLength * baselineInMeters) )
    DisparityFloat32 = c.kCVPixelFormatType_DisparityFloat32,
    /// IEEE754-2008 binary16 (half float), describing the depth (distance to an object) in meters
    DepthFloat16 = c.kCVPixelFormatType_DepthFloat16,
    /// IEEE754-2008 binary32 float, describing the depth (distance to an object) in meters
    DepthFloat32 = c.kCVPixelFormatType_DepthFloat32,
    /// 2 plane YCbCr10 4:2:0, each 10 bits in the MSBs of 16bits, video-range (luma=[64,940] chroma=[64,960])
    @"420YpCbCr10BiPlanarVideoRange" = c.kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    /// 2 plane YCbCr10 4:2:2, each 10 bits in the MSBs of 16bits, video-range (luma=[64,940] chroma=[64,960])
    @"422YpCbCr10BiPlanarVideoRange" = c.kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    /// 2 plane YCbCr10 4:4:4, each 10 bits in the MSBs of 16bits, video-range (luma=[64,940] chroma=[64,960])
    @"444YpCbCr10BiPlanarVideoRange" = c.kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
    /// 2 plane YCbCr10 4:2:0, each 10 bits in the MSBs of 16bits, full-range (Y range 0-1023)
    @"420YpCbCr10BiPlanarFullRange" = c.kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    /// 2 plane YCbCr10 4:2:2, each 10 bits in the MSBs of 16bits, full-range (Y range 0-1023)
    @"422YpCbCr10BiPlanarFullRange" = c.kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
    /// 2 plane YCbCr10 4:4:4, each 10 bits in the MSBs of 16bits, full-range (Y range 0-1023)
    @"444YpCbCr10BiPlanarFullRange" = c.kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
    /// first and second planes as per 420YpCbCr8BiPlanarVideoRange (420v), alpha 8 bits in third plane full-range.  No CVPlanarPixelBufferInfo struct.
    @"420YpCbCr8VideoRange_8A_TriPlanar" = c.kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar,
    /// Single plane Bayer 16-bit little-endian sensor element ("sensel".*) samples from full-size decoding of ProRes RAW images; Bayer pattern (sensel ordering) and other raw conversion information is described via buffer attachments
    @"16VersatileBayer" = c.kCVPixelFormatType_16VersatileBayer,
    /// Single plane 64-bit RGBA (16-bit little-endian samples) from downscaled decoding of ProRes RAW images; components--which may not be co-sited with one another--are sensel values and require raw conversion, information for which is described via buffer attachments
    @"64RGBA_DownscaledProResRAW" = c.kCVPixelFormatType_64RGBA_DownscaledProResRAW,
    /// 2 plane YCbCr16 4:2:2, video-range (luma=[4096,60160] chroma=[4096,61440])
    @"422YpCbCr16BiPlanarVideoRange" = c.kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
    /// 2 plane YCbCr16 4:4:4, video-range (luma=[4096,60160] chroma=[4096,61440])
    @"444YpCbCr16BiPlanarVideoRange" = c.kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
    /// 3 plane video-range YCbCr16 4:4:4 with 16-bit full-range alpha (luma=[4096,60160] chroma=[4096,61440] alpha=[0,65535]).  No CVPlanarPixelBufferInfo struct.
    @"444YpCbCr16VideoRange_16A_TriPlanar" = c.kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
    _,
};
