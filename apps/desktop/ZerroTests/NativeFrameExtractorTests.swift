//
//  NativeFrameExtractorTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 2, Milestone 3) — native-resolution anchor frames (§11).
//  Writes a real source video LARGER than the pipeline's downsample cap, then
//  proves NativeFrameExtractor returns a frame at the source's native pixel
//  dimensions (not the ≤1536px the keyframe path would produce), and that the
//  crop helper bounds the region around a normalized point.
//

import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import Zerro

final class NativeFrameExtractorTests: XCTestCase {

    // 1600×900 is just over ProcessingConfig.maxFrameDimension (1536), so a
    // native extraction (1600 wide) is distinguishable from a downsampled one.
    private let sourceWidth = 1600
    private let sourceHeight = 900

    func testExtractsFrameAtNativeResolution() async throws {
        let url = try await makeSolidVideo(width: sourceWidth, height: sourceHeight)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try await NativeFrameExtractor.frame(atSeconds: 0.3, from: url)
        XCTAssertEqual(image.width, sourceWidth, "frame must be NATIVE width, not downsampled")
        XCTAssertEqual(image.height, sourceHeight, "frame must be NATIVE height, not downsampled")
    }

    func testCropAroundCenterMatchesCropSize() {
        let image = makeSolidCGImage(width: 1600, height: 900)
        let crop = NativeFrameExtractor.crop(image, around: (x: 0.5, y: 0.5), cropSize: 400)
        XCTAssertNotNil(crop)
        XCTAssertEqual(crop?.image.width, 400)
        XCTAssertEqual(crop?.image.height, 400)
        // A centered point lands at the crop center.
        XCTAssertEqual(crop?.pointInCrop.x ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(crop?.pointInCrop.y ?? 0, 0.5, accuracy: 0.01)
    }

    func testCropNearEdgeClampsInsideBounds() {
        let image = makeSolidCGImage(width: 1600, height: 900)
        // A point in the top-left corner: the crop rect can't run off the image.
        let crop = NativeFrameExtractor.crop(image, around: (x: 0.0, y: 0.0), cropSize: 400)
        XCTAssertNotNil(crop)
        // Stays within bounds (≤ requested), never out of range.
        XCTAssertLessThanOrEqual(crop!.image.width, 400)
        XCTAssertLessThanOrEqual(crop!.image.height, 400)
        XCTAssertGreaterThan(crop!.image.width, 0)
        XCTAssertGreaterThan(crop!.image.height, 0)
        // The corner point sits at the crop's top-left, not its center.
        XCTAssertEqual(crop!.pointInCrop.x, 0.0, accuracy: 0.01)
        XCTAssertEqual(crop!.pointInCrop.y, 0.0, accuracy: 0.01)
    }

    func testJPEGEncodeRoundTrips() {
        let image = makeSolidCGImage(width: 64, height: 64)
        let data = NativeFrameExtractor.jpegData(image, quality: 0.9)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
        // Decodes back to a same-sized image.
        let src = CGImageSourceCreateWithData(data! as CFData, nil)
        let decoded = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertEqual(decoded?.width, 64)
        XCTAssertEqual(decoded?.height, 64)
    }

    // MARK: - Helpers

    private func makeSolidCGImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Write a short solid-color H.264 video at exactly `width`×`height`.
    private func makeSolidVideo(width: Int, height: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-src-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 10
        for i in 0..<10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pb = try makePixelBuffer(width: width, height: height)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "test video must write cleanly")
        return url
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw XCTSkip("could not allocate pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 80, CVPixelBufferGetBytesPerRow(buffer) * height) // solid gray
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
