import Metal
import QuartzCore
import OSLog

class Renderer {
	static let MAX_HISTORY = 65536
	static let BUFFER_LEN = MAX_HISTORY * MemoryLayout<Float>.size
	let layer: CAMetalLayer
	let device: MTLDevice
	let queue: MTLCommandQueue
	let buffer: MTLBuffer
	let bufferPtr: UnsafeMutablePointer<Float>
	let indices: MTLBuffer
	let rpdesc: MTLRenderPassDescriptor
	let pipe: MTLRenderPipelineState
	let signpost = OSLog(subsystem: "Renderer", category: .pointsOfInterest)
	var texSize = (width: 0, height: 0)
	public var usePresentDrawable: Bool = true
	public var vsync: Bool = false { didSet { layer.displaySyncEnabled = vsync } }
	public var tripleBuffer: Bool = true { didSet { layer.maximumDrawableCount = tripleBuffer ? 3 : 2 } }
	public var scroll: Bool = true
	public var windowSize: UInt32 = 0
	var msaa: UInt32
	var startPos: UInt32 = 0
	var maxHeightMS: Float = 1000 / 30
	var basePos: UInt64 = 0

	static func fillBuffer(enc: MTLBlitCommandEncoder, buffer: MTLBuffer, fill: (UnsafeMutableRawBufferPointer) -> ()) {
		let len = buffer.length
		let tmp = buffer.device.makeBuffer(length: len)!
		fill(UnsafeMutableRawBufferPointer(start: tmp.contents(), count: len))
		enc.copy(from: tmp, sourceOffset: 0, to: buffer, destinationOffset: 0, size: len)
	}

	init(layer: CAMetalLayer, windowSize: UInt32) {
		device = layer.device!
		msaa = 1
		while device.supportsTextureSampleCount(Int(msaa << 1)) {
			msaa <<= 1
		}
		self.layer = layer
		self.windowSize = windowSize
		layer.displaySyncEnabled = vsync
		queue = device.makeCommandQueue()!
		buffer = device.makeBuffer(length: Self.BUFFER_LEN, options: .cpuCacheModeWriteCombined)!
		buffer.label = "Data"
		indices = device.makeBuffer(length: 16384 * 6 * MemoryLayout<UInt16>.size,
		                            options: .storageModePrivate)!
		indices.label = "Indices"
		bufferPtr = buffer.contents().bindMemory(to: Float.self, capacity: Self.MAX_HISTORY)
		memset(buffer.contents(), 0, Self.BUFFER_LEN)
		rpdesc = MTLRenderPassDescriptor()
		rpdesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		rpdesc.colorAttachments[0].loadAction = .clear
		rpdesc.colorAttachments[0].storeAction = .multisampleResolve
		let lib = device.makeDefaultLibrary()!
		let pdesc = MTLRenderPipelineDescriptor()
		pdesc.colorAttachments[0].pixelFormat = layer.pixelFormat
		pdesc.rasterSampleCount = Int(msaa)
		pdesc.vertexFunction = lib.makeFunction(name: "vs")!
		pdesc.fragmentFunction = lib.makeFunction(name: "fs")!
		pipe = try! device.makeRenderPipelineState(descriptor: pdesc)

		if device.areProgrammableSamplePositionsSupported {
			rpdesc.setSamplePositions((0..<msaa).map { (idx: UInt32) -> MTLSamplePosition in
				return MTLSamplePosition(x: Float(idx * 2 + 1) / Float(msaa * 2), y: idx & 1 == 0 ? 0.25 : 0.75)
			})
		}

		let initCB = queue.makeCommandBuffer()!
		let initEnc = initCB.makeBlitCommandEncoder()!
		Self.fillBuffer(enc: initEnc, buffer: indices) { buf in
			let indices = buf.bindMemory(to: UInt16.self)
			let quads = indices.count / 6
			for i in 0..<quads {
				let base = UInt16(truncatingIfNeeded: i &* 4)
				indices[i &* 6 &+ 0] = base &+ 0
				indices[i &* 6 &+ 1] = base &+ 1
				indices[i &* 6 &+ 2] = base &+ 2
				indices[i &* 6 &+ 3] = base &+ 1
				indices[i &* 6 &+ 4] = base &+ 2
				indices[i &* 6 &+ 5] = base &+ 3
			}
		}
		initEnc.endEncoding()
		initCB.commit()
	}

	func runFrame() {
		let start = DispatchTime.now()
		let drawable: CAMetalDrawable
		os_signpost(.begin, log: signpost, name: "NextDrawable")
		drawable = layer.nextDrawable()!
		os_signpost(.end, log: signpost, name: "NextDrawable")
		let end = DispatchTime.now()
		let cb = queue.makeCommandBuffer()!
		cb.label = "Render CB"
		do {
			let outTex = drawable.texture
			let (width, height) = (outTex.width, outTex.height)
			rpdesc.colorAttachments[0].resolveTexture = outTex
			if texSize.width != width || texSize.height != height {
				let tdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: outTex.pixelFormat, width: width, height: height, mipmapped: false)
				tdesc.usage = .renderTarget
				tdesc.storageMode = .private
				if #available(macOS 11, *), device.supportsFamily(.apple1) {
					tdesc.storageMode = .memoryless
				}
				tdesc.textureType = .type2DMultisample
				tdesc.sampleCount = Int(msaa)
				let tex = device.makeTexture(descriptor: tdesc)!
				tex.label = "MSAA Texture"
				rpdesc.colorAttachments[0].texture = tex
				texSize = (width, height)
			}
		}
		let enc = cb.makeRenderCommandEncoder(descriptor: rpdesc)!
		enc.label = "Main Render"
		let elapsed = end.uptimeNanoseconds - start.uptimeNanoseconds
		bufferPtr[Int(startPos)] = Float(elapsed)
		defer {
			startPos = (startPos &+ 1) % UInt32(Self.MAX_HISTORY)
			basePos = basePos &+ 1
		}

		enc.setRenderPipelineState(pipe)
		enc.setVertexBuffer(buffer, offset: 0, index: 0)
		let heightAdj = 1 / (maxHeightMS * 1_000_000)
		assert(Self.MAX_HISTORY & (Self.MAX_HISTORY - 1) == 0)
		let cfg0 = SIMD4<UInt32>((2 / Float(windowSize)).bitPattern, heightAdj.bitPattern, startPos, UInt32(Self.MAX_HISTORY - 1))
		let cfg1 = SIMD4<UInt32>(scroll ? 0 : windowSize - 1 - UInt32(basePos % UInt64(windowSize)), windowSize, 0, 0)
		withUnsafeBytes(of: (cfg0, cfg1)) { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
		for i in stride(from: 0, to: windowSize, by: 16383) {
			let count = min(windowSize - i, 16383)
			enc.drawIndexedPrimitives(
				type: .triangle,
				indexCount: Int(count) * 6,
				indexType: .uint16,
				indexBuffer: indices,
				indexBufferOffset: 0,
				instanceCount: 1,
				baseVertex: Int(i) * 4,
				baseInstance: 0
			)
		}
		enc.endEncoding()
		if usePresentDrawable {
			cb.present(drawable)
		} else {
			cb.addScheduledHandler { _ in drawable.present() }
		}
		if signpost.signpostsEnabled {
			let signpost = signpost
			let id = OSSignpostID(log: signpost, object: cb)
			os_signpost(.begin, log: signpost, name: "Render", signpostID: id)
			cb.addCompletedHandler { _ in
				os_signpost(.end, log: signpost, name: "Render", signpostID: id)
			}
		}
		cb.commit()
	}
}
