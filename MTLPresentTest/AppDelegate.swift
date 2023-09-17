import Cocoa
import QuartzCore

class View: NSView {
	weak var delegate: AppDelegate!
	var mtlLayer: CAMetalLayer
	init(frame: NSRect, delegate: AppDelegate, layer: CAMetalLayer) {
		self.mtlLayer = layer
		self.delegate = delegate
		super.init(frame: frame)
		self.wantsLayer = true
		self.layer = layer
		resize()
	}
	required init?(coder: NSCoder) {
		fatalError()
	}
	func resize() {
		let frame = self.frame
		let width = frame.width
		mtlLayer.drawableSize = convertToBacking(NSSize(width: width, height: frame.height))
	}
	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		resize()
	}
}

class Responder: NSResponder {
	weak var delegate: AppDelegate!
	init(_ delegate: AppDelegate) {
		self.delegate = delegate
		super.init()
	}
	required init?(coder: NSCoder) {
		fatalError()
	}
	override func keyDown(with event: NSEvent) {
		if let chars = event.characters {
			switch chars {
			case "p":
				delegate.sendMessage(.toggleUsePresentDrawable)
			case "v":
				delegate.sendMessage(.toggleVsync)
			case "t":
				delegate.sendMessage(.toggleTripleBuffer)
			case "s":
				delegate.sendMessage(.toggleScroll)
			case "=":
				delegate.sendMessage(.zoomIn)
			case "-":
				delegate.sendMessage(.zoomOut)
			default:
				break
			}
		}
	}
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
	enum Message {
		case stop
		case setVSync(Bool)
		case setUsePresentDrawable(Bool)
		case setTripleBuffer(Bool)
		case setScroll(Bool)
		case toggleVsync
		case toggleUsePresentDrawable
		case toggleTripleBuffer
		case toggleScroll
		case zoomIn
		case zoomOut
		case setWindow(UInt32)
	}

	@IBOutlet var window: NSWindow!
	var view: View!
	var renderer: Renderer!
	var responder: Responder!
	var thread: Thread!
	var lock = NSLock()
	var messages: [Message] = []

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		let layer = CAMetalLayer()
		layer.device = MTLCreateSystemDefaultDevice()
		let view = View(frame: window.contentRect(forFrameRect: window.frame), delegate: self, layer: layer)
		window.contentView = view
		renderer = Renderer(layer: layer, windowSize: 256)
		thread = Thread(target: self, selector: #selector(threadFunc), object: nil)
		thread.start()
		responder = Responder(self)
		window.makeFirstResponder(responder)
	}

	func applicationWillTerminate(_ aNotification: Notification) {
		sendMessage(.stop)
	}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
		return true
	}

	func sendMessage(_ msg: Message) {
		lock.lock()
		messages.append(msg)
		lock.unlock()
	}

	@objc func threadFunc(obj: NSObject?) {
		pthread_setname_np("Render Thread")
		let renderer = self.renderer!
		var run = true
		while run {
			autoreleasepool {
				do {
					lock.lock()
					defer {
						messages.removeAll(keepingCapacity: true)
						lock.unlock()
					}
					for msg in messages {
						switch msg {
						case .stop:
							run = false
							return
						case .setVSync(let val):
							renderer.vsync = val
						case .setUsePresentDrawable(let val):
							renderer.usePresentDrawable = val
						case .setTripleBuffer(let val):
							renderer.tripleBuffer = val
						case .setScroll(let val):
							renderer.scroll = val
						case .setWindow(let val):
							renderer.windowSize = val
						case .toggleVsync:
							renderer.vsync = !renderer.vsync
							print("vsync: \(renderer.vsync)")
						case .toggleUsePresentDrawable:
							renderer.usePresentDrawable = !renderer.usePresentDrawable
							print("presentDrawable: \(renderer.usePresentDrawable)")
						case .toggleTripleBuffer:
							renderer.tripleBuffer = !renderer.tripleBuffer
							print("tripleBuffer: \(renderer.tripleBuffer)")
						case .toggleScroll:
							renderer.scroll = !renderer.scroll
							print("scroll: \(renderer.scroll)")
						case .zoomIn:
							renderer.windowSize = max(renderer.windowSize / 2, 1)
						case .zoomOut:
							renderer.windowSize = min(renderer.windowSize * 2, UInt32(Renderer.MAX_HISTORY) / 2)
						}
					}
				}
				renderer.runFrame()
			}
		}
	}
}

