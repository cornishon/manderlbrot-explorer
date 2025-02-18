package main

import "core:fmt"
import "vendor:sdl3"

WIDTH :: 800
HEIGHT :: 600

CELL_SIZE :: #config(CELL_SIZE, 8)

View_Box :: struct {
	min_bounds: [2]f64,
	max_bounds: [2]f64,
}

Canvas :: struct {
	using view_box: View_Box,
	size: [2]f64,
	texture: ^sdl3.GPUTexture,
	dirty: bool,
}

main :: proc() {
	must(sdl3.Init({.VIDEO}))
	defer sdl3.Quit()

	sdl3.SetLogPriorities(.TRACE)

	window := must(sdl3.CreateWindow("Mandelbrot Set Viewer", WIDTH, HEIGHT, {.RESIZABLE}))

	gpu := must(sdl3.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil))

	must(sdl3.ClaimWindowForGPUDevice(gpu, window))

	comp_source := #load("./mandelbrot.comp.spv")
	compute_pipeline := must(sdl3.CreateGPUComputePipeline(gpu, sdl3.GPUComputePipelineCreateInfo{
		code_size = len(comp_source),
		code = raw_data(comp_source),
		entrypoint = "main",
		format = {.SPIRV},
		threadcount_x = CELL_SIZE,
		threadcount_y = CELL_SIZE,
		threadcount_z = 1,
		num_uniform_buffers = 1,
		num_readwrite_storage_textures = 1,
	}))

	canvas: Canvas
	canvas_init(&canvas, gpu, {WIDTH, HEIGHT}, View_Box{
		min_bounds = {-2.5, -1.5},
		max_bounds = {1.5, 1.5},
	})

	ev: sdl3.Event
	prev_ticks := sdl3.GetTicks()
	mouse_held: bool
	fullscreen: bool

	main_loop: for {
		curr_ticks := sdl3.GetTicks()
		delta_time := f64(curr_ticks - prev_ticks)/1000
		prev_ticks = curr_ticks

		for sdl3.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				break main_loop
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					break main_loop
				case .F:
					fullscreen = !fullscreen
					sdl3.SetWindowFullscreen(window, fullscreen)
				}
			case .MOUSE_WHEEL:
				mouse_position := screen_to_world(canvas, {f64(ev.wheel.mouse_x), f64(ev.wheel.mouse_y)})
				zoom(&canvas, mouse_position, 1.0 - 5.0 * f64(ev.wheel.y) * delta_time)
			case .MOUSE_BUTTON_UP:
				if ev.button.button == sdl3.BUTTON_LEFT {
					mouse_held = false
				}
			case .MOUSE_BUTTON_DOWN:
				if ev.button.button == sdl3.BUTTON_LEFT {
					mouse_held = true
				}
			case .MOUSE_MOTION:
				if mouse_held {
					delta := screen_to_world(canvas, {f64(ev.motion.xrel), f64(ev.motion.yrel)}) - canvas.min_bounds
					pan(&canvas, delta)
				}
			}
		}

		cmdbuf := sdl3.AcquireGPUCommandBuffer(gpu)
		defer must(sdl3.SubmitGPUCommandBuffer(cmdbuf))

		width, height: u32
		swapchain_texture: ^sdl3.GPUTexture
		must(sdl3.WaitAndAcquireGPUSwapchainTexture(cmdbuf, window, &swapchain_texture, &width, &height))

		if width != u32(canvas.size.x) || height != u32(canvas.size.y) {
			resize(&canvas, gpu, width, height)
		}

		if swapchain_texture != nil {
			if canvas.dirty {
				recompute(gpu, compute_pipeline, &canvas)
			}
			sdl3.BlitGPUTexture(cmdbuf, sdl3.GPUBlitInfo{
				source = {
					texture = canvas.texture,
					w = width,
					h = height,
				},
				destination = {
					texture = swapchain_texture,
					w = width,
					h = height,
				},
				load_op = .DONT_CARE,
			})
		} else {
			fmt.println("not rendering...")
		}
	}
}

must :: proc{must_bool, must_ptr}
must_bool :: proc(condition: bool, expr := #caller_expression(condition), location := #caller_location) {
	fmt.assertf(condition, "{}: {}", expr, sdl3.GetError(), loc = location)
}
must_ptr :: proc(ptr: ^$T, expr := #caller_expression(ptr), location := #caller_location) -> ^T {
	fmt.assertf(ptr != nil, "{}: {}", expr, sdl3.GetError(), loc = location)
	return ptr
}

recompute :: proc(gpu: ^sdl3.GPUDevice, compute_pipeline: ^sdl3.GPUComputePipeline, canvas: ^Canvas) {
	canvas.dirty = false
	cmdbuff := sdl3.AcquireGPUCommandBuffer(gpu)
	defer must(sdl3.SubmitGPUCommandBuffer(cmdbuff))

	sdl3.PushGPUComputeUniformData(cmdbuff, 0, &canvas.view_box, size_of(View_Box))

	texture_binding := sdl3.GPUStorageTextureReadWriteBinding{
		texture = canvas.texture,
	}
	compute_pass := must(sdl3.BeginGPUComputePass(cmdbuff, &texture_binding, 1, nil, 0))
	defer sdl3.EndGPUComputePass(compute_pass)

	sdl3.BindGPUComputePipeline(compute_pass, compute_pipeline)
	sdl3.DispatchGPUCompute(
		compute_pass,
		(u32(canvas.size.x) + CELL_SIZE - 1)/CELL_SIZE,
		(u32(canvas.size.y) + CELL_SIZE - 1)/CELL_SIZE,
		1,
	)
}

resize :: proc(canvas: ^Canvas, gpu: ^sdl3.GPUDevice, width, height: u32) {
	canvas.dirty = true
	old_size := canvas.size
	canvas.size = {f64(width), f64(height)}
	
	size_diff := (canvas.size - old_size) * (canvas.max_bounds - canvas.min_bounds) / old_size
	canvas.max_bounds += size_diff * 0.5
	canvas.min_bounds -= size_diff * 0.5

	sdl3.ReleaseGPUTexture(gpu, canvas.texture)
	
	canvas.texture = must(sdl3.CreateGPUTexture(gpu, sdl3.GPUTextureCreateInfo{
		type = .D2,
		format = .R32G32B32A32_FLOAT,
		usage = {.COMPUTE_STORAGE_WRITE},
		width = width,
		height = height,
		layer_count_or_depth = 1,
		num_levels = 1,
	}))
}

pan :: proc(canvas: ^Canvas, delta: [2]f64) {
	canvas.min_bounds -= delta
	canvas.max_bounds -= delta
	canvas.dirty = true
}

zoom :: proc(canvas: ^Canvas, pivot: [2]f64, scale: f64) {
	zoom_around(&canvas.min_bounds, pivot, scale)
	zoom_around(&canvas.max_bounds, pivot, scale)
	canvas.dirty = true
}

zoom_around :: proc(v: ^[2]f64, pivot: [2]f64, zoom: f64) {
	v^ -= pivot
	v^ *= zoom
	v^ += pivot
}

screen_to_world :: proc(c: Canvas, v: [2]f64) -> [2]f64 {
	return v * (c.max_bounds - c.min_bounds) / c.size + c.min_bounds
}

canvas_init :: proc(canvas: ^Canvas, gpu: ^sdl3.GPUDevice, size: [2]f64, vb: View_Box) {
	canvas.view_box = vb
	canvas.size = size
	resize(canvas, gpu, u32(size.x), u32(size.y))
}
