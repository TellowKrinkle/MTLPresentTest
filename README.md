# MTLPresentTest

Program to test the performance of CAMetalLayer.nextDrawable

Every frame, it draws one new line representing the time it took to acquire the drawable to present to.  Lines are scaled so that the top of the screen represents 33.3ms.

### Controls
Use the following keys to control the application
- `=`: Zoom in
- `-`: Zoom out
- `s`: Switch between scrolling and fixed view
- `p`: Switch between using `[MTLCommandBuffer presentDrawable:]` and `[MTLDrawable present]`
- `t`: Switch between double and triple buffering
- `v`: Toggle vsync
- `m`: Hide cursor
