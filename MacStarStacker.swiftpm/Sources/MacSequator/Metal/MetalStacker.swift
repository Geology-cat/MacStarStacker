import Metal
import MetalKit
import AppKit

/// GPU-accelerated image stacker using Metal.
/// Falls back to CPU (ImageStacker) if Metal is unavailable.
class MetalStacker {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let accumulatePSO:    MTLComputePipelineState
    private let dividePSO:        MTLComputePipelineState
    private let writeResultPSO:   MTLComputePipelineState

    private init(device: MTLDevice,
                 commandQueue: MTLCommandQueue,
                 accumulatePSO: MTLComputePipelineState,
                 dividePSO: MTLComputePipelineState,
                 writeResultPSO: MTLComputePipelineState) {
        self.device         = device
        self.commandQueue   = commandQueue
        self.accumulatePSO  = accumulatePSO
        self.dividePSO      = dividePSO
        self.writeResultPSO = writeResultPSO
    }

    // MARK: - Factory

    static func create() -> MetalStacker? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue  = device.makeCommandQueue() else { return nil }

        // Load Metal library compiled from Stacking.metal (bundled resource)
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            print("MetalStacker: Could not load Metal library: \(error)")
            return nil
        }

        do {
            guard let accumFn  = library.makeFunction(name: "accumulate"),
                  let divideFn = library.makeFunction(name: "divideByCount"),
                  let writeFn  = library.makeFunction(name: "writeResult") else { return nil }

            let accumPSO  = try device.makeComputePipelineState(function: accumFn)
            let dividePSO = try device.makeComputePipelineState(function: divideFn)
            let writePSO  = try device.makeComputePipelineState(function: writeFn)

            return MetalStacker(device: device,
                                commandQueue: queue,
                                accumulatePSO: accumPSO,
                                dividePSO: dividePSO,
                                writeResultPSO: writePSO)
        } catch {
            print("MetalStacker: Pipeline creation failed: \(error)")
            return nil
        }
    }

    // MARK: - Stacking

    /// Average-stack a list of NSImages on the GPU.
    func stackAverage(images: [NSImage]) -> NSImage? {
        guard !images.isEmpty,
              let firstCG = images[0].cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width  = firstCG.width
        let height = firstCG.height
        let pixelCount = width * height

        // Accumulator buffer: float4 per pixel (RGBA)
        let bufferLength = pixelCount * MemoryLayout<SIMD4<Float>>.stride
        guard let accumBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
        else { return nil }

        // Zero the accumulator
        memset(accumBuffer.contents(), 0, bufferLength)

        // Texture descriptor for reading source images
        let texDesc        = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage      = [.shaderRead, .shaderWrite]
        texDesc.storageMode = .shared

        // Accumulate each image
        for image in images {
            guard let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  cgImg.width == width, cgImg.height == height,
                  let srcTexture = texture(from: cgImg, descriptor: texDesc)
            else { continue }

            guard let cmd  = commandQueue.makeCommandBuffer(),
                  let enc  = cmd.makeComputeCommandEncoder() else { continue }

            enc.setComputePipelineState(accumulatePSO)
            enc.setTexture(srcTexture, index: 0)
            enc.setBuffer(accumBuffer, offset: 0, index: 0)
            var w = UInt32(width)
            enc.setBytes(&w, length: 4, index: 1)
            dispatch(enc, pso: accumulatePSO, width: width, height: height)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        // Divide by count
        var count = Float(images.count)
        var total = UInt32(pixelCount)
        guard let cmd2 = commandQueue.makeCommandBuffer(),
              let enc2 = cmd2.makeComputeCommandEncoder() else { return nil }
        enc2.setComputePipelineState(dividePSO)
        enc2.setBuffer(accumBuffer, offset: 0, index: 0)
        enc2.setBytes(&count, length: 4, index: 1)
        enc2.setBytes(&total, length: 4, index: 2)
        let threadgroupSize  = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupCount = MTLSize(width: (pixelCount + 255) / 256, height: 1, depth: 1)
        enc2.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        enc2.endEncoding()
        cmd2.commit()
        cmd2.waitUntilCompleted()

        // Write result to output texture
        let outTexDesc        = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false
        )
        outTexDesc.usage      = [.shaderWrite, .shaderRead]
        outTexDesc.storageMode = .shared
        guard let outTexture = device.makeTexture(descriptor: outTexDesc),
              let cmd3 = commandQueue.makeCommandBuffer(),
              let enc3 = cmd3.makeComputeCommandEncoder() else { return nil }

        enc3.setComputePipelineState(writeResultPSO)
        enc3.setBuffer(accumBuffer, offset: 0, index: 0)
        enc3.setTexture(outTexture, index: 0)
        var w2 = UInt32(width)
        enc3.setBytes(&w2, length: 4, index: 1)
        dispatch(enc3, pso: writeResultPSO, width: width, height: height)
        enc3.endEncoding()
        cmd3.commit()
        cmd3.waitUntilCompleted()

        return nsImage(from: outTexture, width: width, height: height)
    }

    // MARK: - Helpers

    private func texture(from cgImage: CGImage, descriptor: MTLTextureDescriptor) -> MTLTexture? {
        let width  = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [Float](repeating: 0, count: width * height * 4)

        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 32, bytesPerRow: width * 16,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let tex = device.makeTexture(descriptor: descriptor)
        tex?.replace(region: MTLRegionMake2D(0, 0, width, height),
                     mipmapLevel: 0,
                     withBytes: &pixels,
                     bytesPerRow: width * 16)
        return tex
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder,
                          pso: MTLComputePipelineState,
                          width: Int, height: Int) {
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width:  (width  + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
    }

    private func nsImage(from texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: height * rowBytes)
        texture.getBytes(&pixels,
                         bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: rowBytes, space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
