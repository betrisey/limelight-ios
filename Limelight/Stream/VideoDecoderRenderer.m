//
//  VideoDecoderRenderer.m
//  Limelight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Limelight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"

@implementation VideoDecoderRenderer {
    AVSampleBufferDisplayLayer* displayLayer;
    Boolean waitingForSps, waitingForPps;
    
    NSData *spsData, *ppsData;
    CMVideoFormatDescriptionRef formatDesc;
}

- (id)initWithView:(UIView*)view
{
    self = [super init];
    
    displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    displayLayer.bounds = view.bounds;
    displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    displayLayer.position = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [view.layer addSublayer:displayLayer];
    
    // We need some parameter sets before we can properly start decoding frames
    waitingForSps = true;
    waitingForPps = true;
    
    return self;
}

#define FRAME_START_PREFIX_SIZE 4
#define NALU_START_PREFIX_SIZE 3

#define NAL_LENGTH_PREFIX_SIZE 4

- (void)updateBufferForRange:(CMBlockBufferRef)existingBuffer data:(unsigned char *)data offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(existingBuffer);
    
    // If we're at index 1 (first NALU in frame), enqueue this buffer to the memory block
    // so it can handle freeing it when the block buffer is destroyed
    if (offset == 1) {
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        
        // Pass the real buffer pointer directly (no offset)
        // This will give it to the block buffer to free when it's released.
        // All further calls to CMBlockBufferAppendMemoryBlock will do so
        // at an offset and will not be asking the buffer to be freed.
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, data,
                                                nalLength + 1, // Add 1 for the offset we decremented
                                                kCFAllocatorDefault,
                                                NULL, 0, nalLength + 1, 0);
        if (status != noErr) {
            printf("CMBlockBufferReplaceDataBytes failed: %d\n", (int)status);
            return;
        }
        
        // Write the length prefix to existing buffer
        const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
            (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                                               oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            printf("CMBlockBufferReplaceDataBytes failed: %d\n", (int)status);
            return;
        }
    }
    else {
        // Append a 4 byte buffer to this block for the length prefix
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, NULL,
                                                NAL_LENGTH_PREFIX_SIZE,
                                                kCFAllocatorDefault, NULL, 0,
                                                NAL_LENGTH_PREFIX_SIZE, 0);
        if (status != noErr) {
            printf("CMBlockBufferAppendMemoryBlock failed: %d\n", (int)status);
            return;
        }
        
        // Write the length prefix to the new buffer
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
            (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                                               oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            printf("CMBlockBufferReplaceDataBytes failed: %d\n", (int)status);
            return;
        }
        
        // Attach the buffer by reference to the block buffer
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, &data[offset+NALU_START_PREFIX_SIZE],
                                                dataLength,
                                                kCFAllocatorNull, // Don't deallocate data on free
                                                NULL, 0, dataLength, 0);
        if (status != noErr) {
            printf("CMBlockBufferReplaceDataBytes failed: %d\n", (int)status);
            return;
        }
    }
}

// This function must free data
- (void)submitDecodeBuffer:(unsigned char *)data length:(int)length
{
    unsigned char nalType = data[FRAME_START_PREFIX_SIZE] & 0x1F;
    OSStatus status;
    
    if (nalType == 0x7 || nalType == 0x8) {
        if (nalType == 0x7) {
            printf("Got SPS\n");
            spsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForSps = false;
            
            // We got a new SPS so wait for a new PPS to match it
            waitingForPps = true;
        }
        else if (nalType == 0x8) {
            printf("Got PPS\n");
            ppsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForPps = false;
        }
        
        // See if we've got all the parameter sets we need
        if (!waitingForSps && !waitingForPps) {
            const uint8_t* const parameterSetPointers[] = { [spsData bytes], [ppsData bytes] };
            const size_t parameterSetSizes[] = { [spsData length], [ppsData length] };
            
            printf("Constructing new format description\n");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         2, /* count of parameter sets */
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &formatDesc);
            if (status != noErr) {
                printf("Failed to create format description: %d\n", (int)status);
                formatDesc = NULL;
            }
        }
        
        // Free the data buffer
        free(data);
        
        // No frame data to submit for these NALUs
        return;
    }
    
    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return;
    }
    
    if (nalType != 0x1 && nalType != 0x5) {
        // Don't submit parameter set data
        free(data);
        return;
    }
    
    // Now we're decoding actual frame data here
    CMBlockBufferRef blockBuffer;
    
    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &blockBuffer);
    if (status != noErr) {
        printf("CMBlockBufferCreateEmpty failed: %d\n", (int)status);
        free(data);
        return;
    }
    
    int lastOffset = -1;
    for (int i = 0; i < length - FRAME_START_PREFIX_SIZE; i++) {
        // Search for a NALU
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            // It's the start of a new NALU
            if (lastOffset != -1) {
                // We've seen a start before this so enqueue that NALU
                [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:i - lastOffset];
            }
            
            lastOffset = i;
        }
    }
    
    if (lastOffset != -1) {
        // Enqueue the remaining data
        [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:length - lastOffset];
    }
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    
    CMSampleBufferRef sampleBuffer;
    
    status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  blockBuffer,
                                  true, NULL,
                                  NULL, formatDesc, 1, 0,
                                  NULL, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        printf("CMSampleBufferCreate failed: %d\n", (int)status);
        CFRelease(blockBuffer);
        return;
    }
    
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_IsDependedOnByOthers, kCFBooleanTrue);
    
    if (nalType == 1) {
        // P-frame
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
    }
    else {
        // I-frame
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanFalse);
    }
    
    [displayLayer enqueueSampleBuffer:sampleBuffer];
    
    // Dereference the buffers
    CFRelease(blockBuffer);
    CFRelease(sampleBuffer);
}

@end
