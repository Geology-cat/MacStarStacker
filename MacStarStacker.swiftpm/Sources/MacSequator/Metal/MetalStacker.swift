import Metal
import AppKit

/// GPU-accelerated image stacker using Metal.
/// Falls back to CPU (ImageStacker) if Metal is unavailable.
class MetalStacker {

    private static let cachedInstance: MetalStacker? = makeInstance()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let accumulatePSO:    MTLComputePipelineState
    private let dividePSO:        MTLComputePipelineState

    private init(device: MTLDevice,
                 commandQueue: MTLCommandQueue,
                 accumulatePSO: MTLComputePipelineState,
                 dividePSO: MTLComputePipelineState) {
        self.device         = device
        self.commandQueue   = commandQueue
        self.accumulatePSO  = accumulatePSO
        self.dividePSO      = dividePSO
    }

    // MARK: - Factory

    static func create() -> MetalStacker? {
        cachedInstance
    }

    private static func makeInstance() -> MetalStacker? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue  = device.makeCommandQueue() else { return nil }

        // SwiftPM は .metal をソースのままリソースへ格納するため、metallib が無い場合は
        // バンドル内ソースを一度だけコンパイルしてキャッシュする。
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            guard let sourceURL = Bundle.module.url(forResource: "Stacking", withExtension: "metal"),
                  let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
                print("MetalStacker: Metalシェーダーを読み込めませんでした: \(error.localizedDescription)")
                return nil
            }
            do {
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                print("MetalStacker: Metalシェーダーをコンパイルできませんでした: \(error.localizedDescription)")
                return nil
            }
        }

        do {
            guard let accumFn  = library.makeFunction(name: "accumulate"),
                  let divideFn = library.makeFunction(name: "divideByCount") else { return nil }

            let accumPSO  = try device.makeComputePipelineState(function: accumFn)
            let dividePSO = try device.makeComputePipelineState(function: divideFn)

            return MetalStacker(device: device,
                                commandQueue: queue,
                                accumulatePSO: accumPSO,
                                dividePSO: dividePSO)
        } catch {
            print("MetalStacker: Metalパイプラインを生成できませんでした: \(error.localizedDescription)")
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
        let cgImages = images.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard cgImages.count == images.count,
              cgImages.allSatisfy({ $0.width == width && $0.height == height }) else { return nil }

        // Accumulator buffer: float4 per pixel (RGBA)
        let bufferLength = pixelCount * MemoryLayout<SIMD4<Float>>.stride
        guard let accumBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
        else { return nil }

        // Zero the accumulator
        memset(accumBuffer.contents(), 0, bufferLength)

        // Accumulate each image
        var processedCount = 0
        for cgImg in cgImages {
            guard let srcTexture = texture(from: cgImg) else { return nil }

            guard let cmd  = commandQueue.makeCommandBuffer(),
                  let enc  = cmd.makeComputeCommandEncoder() else { return nil }

            enc.setComputePipelineState(accumulatePSO)
            enc.setTexture(srcTexture, index: 0)
            enc.setBuffer(accumBuffer, offset: 0, index: 0)
            var w = UInt32(width)
            enc.setBytes(&w, length: 4, index: 1)
            dispatch(enc, pso: accumulatePSO, width: width, height: height)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            guard cmd.status == .completed else { return nil }
            processedCount += 1
        }

        // Divide by count
        guard processedCount == images.count else { return nil }
        var count = Float(processedCount)
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
        guard cmd2.status == .completed else { return nil }

        return nsImage(from: accumBuffer, width: width, height: height)
    }

    // MARK: - Helpers

    private func texture(from cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width, height = cgImage.height
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress, width: width, height: height,
                    bitsPerComponent: 32, bytesPerRow: width * 16,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: baseAddress, bytesPerRow: width * 16
            )
        }
        return texture
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

    private func nsImage(from buffer: MTLBuffer, width: Int, height: Int) -> NSImage? {
        let pixelCount = width * height
        let source = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixelCount)
        var pixels = [UInt16](repeating: 0, count: pixelCount * 4)
        for index in 0..<pixelCount {
            let value = source[index]
            pixels[index * 4] = UInt16(max(0, min(65_535, value.x * 65_535)).rounded())
            pixels[index * 4 + 1] = UInt16(max(0, min(65_535, value.y * 65_535)).rounded())
            pixels[index * 4 + 2] = UInt16(max(0, min(65_535, value.z * 65_535)).rounded())
            pixels[index * 4 + 3] = UInt16(max(0, min(65_535, value.w * 65_535)).rounded())
        }
        let rowBytes = width * 8
        let data = pixels.withUnsafeBytes { Data($0) }
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 16, bitsPerPixel: 64,
                  bytesPerRow: rowBytes, space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                  ),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
