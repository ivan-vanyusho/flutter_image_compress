//
// Created by cjl on 2018/9/8.
//

#import "CompressHandler.h"
#import "UIImage+scale.h"
#import "ImageCompressPlugin.h"
@import ImageIO;
@import SDWebImageWebPCoder;
#if __has_include(<libwebp/mux.h>)
#import <libwebp/decode.h>
#import <libwebp/mux.h>
#else
#import <webp/decode.h>
#import <webp/mux.h>
#endif

static uint16_t FICReadUInt16(const uint8_t *bytes, NSUInteger offset, BOOL littleEndian) {
    if (littleEndian) {
        return (uint16_t)(bytes[offset] | (bytes[offset + 1] << 8));
    }
    return (uint16_t)((bytes[offset] << 8) | bytes[offset + 1]);
}

static uint32_t FICReadUInt32(const uint8_t *bytes, NSUInteger offset, BOOL littleEndian) {
    if (littleEndian) {
        return (uint32_t)bytes[offset]
            | ((uint32_t)bytes[offset + 1] << 8)
            | ((uint32_t)bytes[offset + 2] << 16)
            | ((uint32_t)bytes[offset + 3] << 24);
    }
    return ((uint32_t)bytes[offset] << 24)
        | ((uint32_t)bytes[offset + 1] << 16)
        | ((uint32_t)bytes[offset + 2] << 8)
        | (uint32_t)bytes[offset + 3];
}

static void FICWriteUInt16(uint8_t *bytes, NSUInteger offset, uint16_t value, BOOL littleEndian) {
    if (littleEndian) {
        bytes[offset] = (uint8_t)(value & 0xff);
        bytes[offset + 1] = (uint8_t)(value >> 8);
    } else {
        bytes[offset] = (uint8_t)(value >> 8);
        bytes[offset + 1] = (uint8_t)(value & 0xff);
    }
}

static void FICWriteUInt32(uint8_t *bytes, NSUInteger offset, uint32_t value, BOOL littleEndian) {
    if (littleEndian) {
        bytes[offset] = (uint8_t)(value & 0xff);
        bytes[offset + 1] = (uint8_t)((value >> 8) & 0xff);
        bytes[offset + 2] = (uint8_t)((value >> 16) & 0xff);
        bytes[offset + 3] = (uint8_t)(value >> 24);
    } else {
        bytes[offset] = (uint8_t)(value >> 24);
        bytes[offset + 1] = (uint8_t)((value >> 16) & 0xff);
        bytes[offset + 2] = (uint8_t)((value >> 8) & 0xff);
        bytes[offset + 3] = (uint8_t)(value & 0xff);
    }
}

static void FICWriteIFDValue(uint8_t *bytes, NSUInteger entryOffset, uint16_t type, uint32_t value,
                             BOOL littleEndian) {
    if (type == 3 && value <= UINT16_MAX) { // SHORT
        FICWriteUInt16(bytes, entryOffset + 8, (uint16_t)value, littleEndian);
        bytes[entryOffset + 10] = 0;
        bytes[entryOffset + 11] = 0;
    } else if (type == 4) { // LONG
        FICWriteUInt32(bytes, entryOffset + 8, value, littleEndian);
    }
}

static uint32_t FICPatchIFD(uint8_t *bytes, NSUInteger length, uint32_t ifdOffset, BOOL littleEndian,
                            uint32_t width, uint32_t height, BOOL exifIFD) {
    if (ifdOffset > length || length - ifdOffset < 2) {
        return 0;
    }

    uint16_t entryCount = FICReadUInt16(bytes, ifdOffset, littleEndian);
    NSUInteger entriesOffset = (NSUInteger)ifdOffset + 2;
    if (entryCount > (length - entriesOffset) / 12) {
        return 0;
    }

    uint32_t nestedExifOffset = 0;
    for (uint16_t index = 0; index < entryCount; index++) {
        NSUInteger entryOffset = entriesOffset + (NSUInteger)index * 12;
        uint16_t tag = FICReadUInt16(bytes, entryOffset, littleEndian);
        uint16_t type = FICReadUInt16(bytes, entryOffset + 2, littleEndian);
        uint32_t count = FICReadUInt32(bytes, entryOffset + 4, littleEndian);
        if (count != 1) {
            continue;
        }

        if (!exifIFD && tag == 0x8769 && type == 4) { // ExifIFDPointer
            nestedExifOffset = FICReadUInt32(bytes, entryOffset + 8, littleEndian);
        } else if (!exifIFD && tag == 0x0112) { // Orientation
            FICWriteIFDValue(bytes, entryOffset, type, 1, littleEndian);
        } else if (!exifIFD && tag == 0x0100) { // ImageWidth
            FICWriteIFDValue(bytes, entryOffset, type, width, littleEndian);
        } else if (!exifIFD && tag == 0x0101) { // ImageLength
            FICWriteIFDValue(bytes, entryOffset, type, height, littleEndian);
        } else if (exifIFD && tag == 0xa002) { // PixelXDimension
            FICWriteIFDValue(bytes, entryOffset, type, width, littleEndian);
        } else if (exifIFD && tag == 0xa003) { // PixelYDimension
            FICWriteIFDValue(bytes, entryOffset, type, height, littleEndian);
        }
    }
    return nestedExifOffset;
}

static BOOL FICNormalizeTIFFData(NSMutableData *data, uint32_t width, uint32_t height) {
    if (data.length < 8) {
        return NO;
    }

    uint8_t *bytes = data.mutableBytes;
    BOOL littleEndian;
    if (bytes[0] == 'I' && bytes[1] == 'I') {
        littleEndian = YES;
    } else if (bytes[0] == 'M' && bytes[1] == 'M') {
        littleEndian = NO;
    } else {
        return NO;
    }
    if (FICReadUInt16(bytes, 2, littleEndian) != 42) {
        return NO;
    }

    uint32_t ifdOffset = FICReadUInt32(bytes, 4, littleEndian);
    uint32_t exifOffset = FICPatchIFD(bytes, data.length, ifdOffset, littleEndian, width, height, NO);
    if (exifOffset != 0) {
        FICPatchIFD(bytes, data.length, exifOffset, littleEndian, width, height, YES);
    }
    return YES;
}

static NSData *FICExtractTIFFDataFromJPEG(NSData *jpegData) {
    const uint8_t *bytes = jpegData.bytes;
    NSUInteger length = jpegData.length;
    if (length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
        return nil;
    }

    NSUInteger offset = 2;
    while (offset + 4 <= length) {
        if (bytes[offset] != 0xff) {
            return nil;
        }
        while (offset < length && bytes[offset] == 0xff) {
            offset++;
        }
        if (offset >= length) {
            return nil;
        }

        uint8_t marker = bytes[offset++];
        if (marker == 0xd9 || marker == 0xda) {
            break;
        }
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
            continue;
        }
        if (offset + 2 > length) {
            return nil;
        }

        uint16_t segmentLength = (uint16_t)((bytes[offset] << 8) | bytes[offset + 1]);
        if (segmentLength < 2 || segmentLength > length - offset) {
            return nil;
        }
        NSUInteger payloadOffset = offset + 2;
        NSUInteger payloadLength = segmentLength - 2;
        if (marker == 0xe1 && payloadLength >= 6
            && memcmp(bytes + payloadOffset, "Exif\0\0", 6) == 0) {
            return [jpegData subdataWithRange:NSMakeRange(payloadOffset + 6, payloadLength - 6)];
        }
        offset += segmentLength;
    }
    return nil;
}

static NSData *FICCreateTIFFData(NSDictionary *sourceProperties, uint32_t width, uint32_t height) {
    NSDictionary *sourceExif = sourceProperties[(NSString *)kCGImagePropertyExifDictionary];
    NSDictionary *sourceTIFF = sourceProperties[(NSString *)kCGImagePropertyTIFFDictionary];
    NSDictionary *sourceGPS = sourceProperties[(NSString *)kCGImagePropertyGPSDictionary];
    NSNumber *sourceOrientation = sourceProperties[(NSString *)kCGImagePropertyOrientation];
    if (sourceExif.count == 0 && sourceTIFF.count == 0 && sourceGPS.count == 0 && sourceOrientation == nil) {
        return nil;
    }

    NSMutableDictionary *properties = [sourceProperties mutableCopy];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyPixelWidth];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyPixelHeight];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyFileSize];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyProfileName];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyColorModel];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyDepth];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyHasAlpha];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyIsFloat];
    [properties removeObjectForKey:(NSString *)kCGImagePropertyIsIndexed];
    properties[(NSString *)kCGImagePropertyOrientation] = @1;

    NSMutableDictionary *tiff = sourceTIFF != nil ? [sourceTIFF mutableCopy] : [NSMutableDictionary dictionary];
    tiff[(NSString *)kCGImagePropertyTIFFOrientation] = @1;
    properties[(NSString *)kCGImagePropertyTIFFDictionary] = tiff;

    if (sourceExif != nil) {
        NSMutableDictionary *exif = [sourceExif mutableCopy];
        exif[(NSString *)kCGImagePropertyExifPixelXDimension] = @(width);
        exif[(NSString *)kCGImagePropertyExifPixelYDimension] = @(height);
        properties[(NSString *)kCGImagePropertyExifDictionary] = exif;
    }

    uint8_t pixel[4] = {0, 0, 0, 255};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        return nil;
    }
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return nil;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == NULL) {
        return nil;
    }

    NSMutableData *jpegData = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)jpegData, CFSTR("public.jpeg"), 1, NULL);
    if (destination == NULL) {
        CGImageRelease(image);
        return nil;
    }
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    if (!success) {
        return nil;
    }

    NSData *rawTIFFData = FICExtractTIFFDataFromJPEG(jpegData);
    if (rawTIFFData.length == 0) {
        return nil;
    }
    NSMutableData *tiffData = [rawTIFFData mutableCopy];
    return FICNormalizeTIFFData(tiffData, width, height) ? tiffData : nil;
}

@implementation CompressHandler {

}

+ (NSData *)compressWithData:(NSData *)data minWidth:(int)minWidth minHeight:(int)minHeight quality:(int)quality
                      rotate:(int)rotate format:(int)format {
    UIImage *img = [self isWebP:data] ? [UIImage sd_imageWithWebPData:data] : [[UIImage alloc] initWithData:data];
    return [CompressHandler compressWithUIImage:img minWidth:minWidth minHeight:minHeight quality:quality rotate:rotate format:format];
}

+ (NSData *)compressWithUIImage:(UIImage *)image minWidth:(int)minWidth minHeight:(int)minHeight quality:(int)quality
                         rotate:(int)rotate format:(int)format {
    if([ImageCompressPlugin showLog]){
        NSLog(@"width = %.0f",[image size].width);
        NSLog(@"height = %.0f",[image size].height);
        NSLog(@"minWidth = %d",minWidth);
        NSLog(@"minHeight = %d",minHeight);
        NSLog(@"format = %d", format);
    }

    image = [image scaleWithMinWidth:minWidth minHeight:minHeight];
    if(rotate % 360 != 0){
        image = [image rotate: rotate];
    }
    NSData *resultData = [self compressDataWithImage:image quality:quality format:format];

    return resultData;
}


+ (NSData *)compressDataWithUIImage:(UIImage *)image minWidth:(int)minWidth minHeight:(int)minHeight
                            quality:(int)quality rotate:(int)rotate format:(int)format {
    image = [image scaleWithMinWidth:minWidth minHeight:minHeight];
    if(rotate % 360 != 0){
        image = [image rotate: rotate];
    }
    return [self compressDataWithImage:image quality:quality format:format];
}

+ (NSData *)compressDataWithImage:(UIImage *)image quality:(float)quality format:(int)format  {
    NSData *data;
    if (format == 2) { // heic
        CIImage *ciImage = [CIImage imageWithCGImage:image.CGImage];
        CIContext *ciContext = [[CIContext alloc]initWithOptions:nil];
        NSString *tmpDir = NSTemporaryDirectory();
        NSString *target = [NSString stringWithFormat:@"%@%@.heic", tmpDir, [[NSUUID UUID] UUIDString]];
        NSURL *url = [NSURL fileURLWithPath:target];

        NSMutableDictionary *options = [NSMutableDictionary new];
        NSString *qualityKey = (__bridge NSString *)kCGImageDestinationLossyCompressionQuality;
//        CIImageRepresentationOption
        [options setObject:@(quality / 100) forKey: qualityKey];

        if (@available(iOS 11.0, *)) {
            CGColorSpaceRef colorSpace = ciImage.colorSpace;
            if (colorSpace == NULL) {
                colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            }

            NSError *error = nil;
            BOOL success = [ciContext writeHEIFRepresentationOfImage:ciImage toURL:url format:kCIFormatARGB8 colorSpace:colorSpace options:options error:&error];

            if (success) {
                data = [NSData dataWithContentsOfURL:url];
            } else {
                data = nil;
                if([ImageCompressPlugin showLog]){
                    NSLog(@"HEIC write failed: %@", error.localizedDescription);
                }
            }

            if (colorSpace != ciImage.colorSpace) {
                CGColorSpaceRelease(colorSpace);
            }

            // Always attempt cleanup; ignore errors (file may already be gone
            // or may have been partially written on failure).
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        } else {
            // Fallback on earlier versions
            data = nil;
        }
    } else if(format == 3){ // webp
        SDImageCoderOptions *option = @{SDImageCoderEncodeCompressionQuality: @(quality / 100)};
        data = [[SDImageWebPCoder sharedCoder]encodedDataWithImage:image format:SDImageFormatWebP options:option];
    } else if(format == 1){ // png
        data = UIImagePNGRepresentation(image);
    }else { // 0 or other is jpeg
        data = UIImageJPEGRepresentation(image, (CGFloat) quality / 100);
    }

    return data;
}

+ (BOOL)isWebP:(NSData *)data {
    if (data.length < 12) return false;

    NSData *riff = [data subdataWithRange:NSMakeRange(8, 4)];
    NSString* format = [[NSString alloc] initWithData:riff encoding:(NSASCIIStringEncoding)];

    return [format isEqualToString:@"WEBP"];
}

+ (NSData *)dataByCopyingMetadataFromSource:(NSData *)sourceData
                                intoEncoded:(NSData *)encodedData {
    if (sourceData.length == 0 || encodedData.length == 0) {
        return nil;
    }

    if ([self isWebP:encodedData]) {
        return [self webPDataByCopyingMetadataFromSource:sourceData intoEncoded:encodedData];
    }

    CGImageSourceRef sourceRef = CGImageSourceCreateWithData((__bridge CFDataRef)sourceData, NULL);
    if (sourceRef == NULL) {
        if ([ImageCompressPlugin showLog]) {
            NSLog(@"keepExif: could not read source metadata (unsupported container)");
        }
        return nil;
    }

    NSDictionary *rawSourceProps = (NSDictionary *)CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, NULL));
    CFRelease(sourceRef);

    if (rawSourceProps == nil) {
        return nil;
    }

    CGImageSourceRef encodedRef = CGImageSourceCreateWithData((__bridge CFDataRef)encodedData, NULL);
    if (encodedRef == NULL) {
        return nil;
    }
    CFStringRef encodedType = CGImageSourceGetType(encodedRef);
    if (encodedType == NULL) {
        CFRelease(encodedRef);
        return nil;
    }

    NSMutableData *mergedData = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)mergedData, encodedType, 1, NULL);
    if (destination == NULL) {
        // ImageIO can't author this container (notably WebP). Signal the caller
        // to keep the original encoded bytes so we don't crash downstream.
        if ([ImageCompressPlugin showLog]) {
            NSLog(@"keepExif: CGImageDestination for type %@ is not available; keeping compressed bytes without metadata", (__bridge NSString *)encodedType);
        }
        CFRelease(encodedRef);
        return nil;
    }

    // The pipeline scales and (optionally) rotates before re-encoding, so the
    // source's PixelWidth/PixelHeight and Orientation no longer describe the
    // encoded pixels. Overwrite them so viewers don't double-rotate or read
    // stale dimensions. Also drop keys that describe the source's *pixel
    // buffer* (color profile, depth, alpha channel, indexed/float model) —
    // those describe the source, not the re-encoded output. Passing a stale
    // ProfileName from a Display-P3 source into an sRGB JPEG output makes
    // color-managed viewers apply the wrong transform (visibly wrong colors);
    // passing HasAlpha=YES from a transparent PNG source into a JPEG (which
    // has no alpha) writes contradictory metadata.
    NSMutableDictionary *props = [rawSourceProps mutableCopy];
    [props removeObjectForKey:(NSString *)kCGImagePropertyPixelWidth];
    [props removeObjectForKey:(NSString *)kCGImagePropertyPixelHeight];
    [props removeObjectForKey:(NSString *)kCGImagePropertyFileSize];
    [props removeObjectForKey:(NSString *)kCGImagePropertyProfileName];
    [props removeObjectForKey:(NSString *)kCGImagePropertyColorModel];
    [props removeObjectForKey:(NSString *)kCGImagePropertyDepth];
    [props removeObjectForKey:(NSString *)kCGImagePropertyHasAlpha];
    [props removeObjectForKey:(NSString *)kCGImagePropertyIsFloat];
    [props removeObjectForKey:(NSString *)kCGImagePropertyIsIndexed];
    props[(NSString *)kCGImagePropertyOrientation] = @1;

    NSDictionary *tiffDict = props[(NSString *)kCGImagePropertyTIFFDictionary];
    if ([tiffDict isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *tiff = [tiffDict mutableCopy];
        tiff[(NSString *)kCGImagePropertyTIFFOrientation] = @1;
        props[(NSString *)kCGImagePropertyTIFFDictionary] = tiff;
    }

    NSDictionary *exifDict = props[(NSString *)kCGImagePropertyExifDictionary];
    if ([exifDict isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *exif = [exifDict mutableCopy];
        [exif removeObjectForKey:(NSString *)kCGImagePropertyExifPixelXDimension];
        [exif removeObjectForKey:(NSString *)kCGImagePropertyExifPixelYDimension];
        props[(NSString *)kCGImagePropertyExifDictionary] = exif;
    }

    CGImageDestinationAddImageFromSource(destination, encodedRef, 0,
                                         (__bridge CFDictionaryRef)props);
    BOOL success = CGImageDestinationFinalize(destination);

    CFRelease(destination);
    CFRelease(encodedRef);

    if (!success) {
        if ([ImageCompressPlugin showLog]) {
            NSLog(@"keepExif: CGImageDestinationFinalize failed");
        }
        return nil;
    }
    // Finalize can return YES while AddImageFromSource silently no-ops.
    // Treat zero-length output as failure so the caller falls back to the
    // original encoded bytes.
    return mergedData.length > 0 ? mergedData : nil;
}

+ (NSData *)webPDataByCopyingMetadataFromSource:(NSData *)sourceData
                                     intoEncoded:(NSData *)encodedData {
    int width = 0;
    int height = 0;
    if (!WebPGetInfo(encodedData.bytes, encodedData.length, &width, &height) || width <= 0 || height <= 0) {
        return nil;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)sourceData, NULL);
    if (source == NULL) {
        return nil;
    }

    NSDictionary *metadata = (NSDictionary *)CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    if (metadata == nil) {
        return nil;
    }

    NSData *metadataData = FICCreateTIFFData(metadata, (uint32_t)width, (uint32_t)height);
    if (metadataData.length == 0) {
        return nil;
    }

    WebPData webPData = {encodedData.bytes, encodedData.length};
    WebPMux *mux = WebPMuxCreate(&webPData, 1);
    if (mux == NULL) {
        return nil;
    }

    WebPData exifData = {metadataData.bytes, metadataData.length};
    if (WebPMuxSetChunk(mux, "EXIF", &exifData, 0) != WEBP_MUX_OK) {
        WebPMuxDelete(mux);
        return nil;
    }

    WebPData outputData = {0};
    if (WebPMuxAssemble(mux, &outputData) != WEBP_MUX_OK) {
        WebPMuxDelete(mux);
        return nil;
    }

    NSData *result = [NSData dataWithBytes:outputData.bytes length:outputData.size];
    WebPDataClear(&outputData);
    WebPMuxDelete(mux);
    return result;
}

@end
