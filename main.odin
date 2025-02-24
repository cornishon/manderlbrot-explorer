package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import m "core:math/linalg/glsl"
import "vendor:sdl3"
import mu "vendor:microui"

FACTOR :: 67
WIDTH :: 15 * FACTOR
HEIGHT :: 10 * FACTOR
ZOOM_SPEED :: 0.25

CELL_SIZE :: #config(CELL_SIZE, 8)

View_Box :: struct {
	min_bounds: m.dvec2,
	max_bounds: m.dvec2,
}

Canvas :: struct {
	using view_box: View_Box,
	size: m.dvec2,
	texture: ^sdl3.GPUTexture,
	palette_buffer: ^sdl3.GPUBuffer,
	dirty: bool,
}

Params :: struct {
	max_iter: f32,
}

main :: proc() {
	must(sdl3.Init({.VIDEO}))
	defer sdl3.Quit()

	mu_ctx := new(mu.Context)

	mu.init(mu_ctx,
		proc(_: rawptr, text: string) -> bool {
			return sdl3.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
		},
		proc(_: rawptr) -> (text: string, ok: bool) {
			if sdl3.HasClipboardText() {
				return string(cstring(sdl3.GetClipboardText())), true
			}
			return
		},
	)
	mu_ctx.style.colors[.WINDOW_BG].a = 200
	mu_ctx.style.colors[.PANEL_BG].a = 200
	mu_ctx.text_width = mu.default_atlas_text_width
	mu_ctx.text_height = mu.default_atlas_text_height

	sdl3.SetLogPriorities(.TRACE)

	window := must(sdl3.CreateWindow("Mandelbrot Set Viewer", WIDTH, HEIGHT, {.RESIZABLE}))

	gpu := must(sdl3.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil))

	must(sdl3.ClaimWindowForGPUDevice(gpu, window))

	canvas: Canvas
	canvas_init(&canvas, gpu, {WIDTH, HEIGHT}, View_Box{
		min_bounds = {(-WIDTH/FACTOR*0.1 - 0.5)*1.3, -HEIGHT/FACTOR*0.1*1.3},
		max_bounds = {( WIDTH/FACTOR*0.1 - 0.5)*1.3,  HEIGHT/FACTOR*0.1*1.3},
	})

	comp_source := #load("./mandelbrot.comp.spv")
	compute_pipeline := must(sdl3.CreateGPUComputePipeline(gpu, sdl3.GPUComputePipelineCreateInfo{
		code_size = len(comp_source),
		code = raw_data(comp_source),
		entrypoint = "main",
		format = {.SPIRV},
		threadcount_x = CELL_SIZE,
		threadcount_y = CELL_SIZE,
		threadcount_z = 1,
		num_uniform_buffers = 2,
		num_readwrite_storage_textures = 1,
		num_readonly_storage_buffers = 1,
	}))

	ui_ctx: UI_Context
	ui_context_init(&ui_ctx, gpu, window)

	params := Params{
		max_iter = 400,
	}

	ev: sdl3.Event
	fullscreen: bool
	mouse_coords: m.dvec2
	zoom_level := 3.0

	must(sdl3.StartTextInput(window))
	main_loop: for {
		free_all(context.temp_allocator)

		for sdl3.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				break main_loop
			case .TEXT_INPUT:
				mu.input_text(mu_ctx, string(ev.text.text))
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					break main_loop
				case .F11:
					fullscreen = !fullscreen
					sdl3.SetWindowFullscreen(window, fullscreen)
				case:
					mu_input_key(mu_ctx, ev.key)
				}
			case .KEY_UP:
				mu_input_key(mu_ctx, ev.key)
			case .MOUSE_WHEEL:
				mu.input_scroll(mu_ctx, i32(ev.wheel.x) * 30, i32(ev.wheel.y) * -30)
				if mu_ctx.hover_root == nil {
					mouse_coords = screen_to_world(canvas, ev.wheel.mouse_x, ev.wheel.mouse_y)
					t := math.sign(f64(ev.wheel.y))
					zoom(&canvas, mouse_coords, math.pow(2, -ZOOM_SPEED * t))
					zoom_level += t * ZOOM_SPEED
				}
			case .MOUSE_BUTTON_UP, .MOUSE_BUTTON_DOWN:
				mu_input_mouse_button(mu_ctx, ev.button)
			case .MOUSE_MOTION:
				m := ev.motion
				mouse_coords = screen_to_world(canvas, m.x, m.y)
				mu.input_mouse_move(mu_ctx, i32(m.x), i32(m.y))
				if mu_ctx.hover_root == nil && .LEFT in m.state {
					delta := screen_to_world(canvas, m.xrel, m.yrel) - canvas.min_bounds
					pan(&canvas, delta)
				}
			}
		}

		mu.begin(mu_ctx)
		if mu.window(mu_ctx, "Controls", {0, 0, 300, 200}) {
			mu.layout_row(mu_ctx, {90, -1})

			mu.label(mu_ctx, "Max Iterations:")
			if .CHANGE in mu.slider(mu_ctx, &params.max_iter, 50, 2000, 10) {
				canvas.dirty = true
			}

			center := (canvas.max_bounds + canvas.min_bounds)/2
			mu.label(mu_ctx, "Zoom Level:")
			z := f32(zoom_level)
			if .CHANGE in mu.slider(mu_ctx, &z, 1.0, 48.0, ZOOM_SPEED) {
				zoom(&canvas, center, math.pow(2, zoom_level - f64(z)))
				zoom_level = f64(z)
			}

			mu.layout_row(mu_ctx, {-1})
			mu.text(mu_ctx, fmt.tprintf(" center x = {}",  center.x))
			mu.text(mu_ctx, fmt.tprintf(" center y = {}", -center.y))
			mu.text(mu_ctx, fmt.tprintf(" mouse x = {}",  mouse_coords.x))
			mu.text(mu_ctx, fmt.tprintf(" mouse y = {}", -mouse_coords.y))
		}
		mu.end(mu_ctx)

		cmd: ^mu.Command
		for variant in mu.next_command_iterator(mu_ctx, &cmd) {
			switch v in variant {
			case ^mu.Command_Rect:
				draw_rect(&ui_ctx, v.rect, v.color)
			case ^mu.Command_Text:
				draw_text(&ui_ctx, v.str, v.pos, v.color)
			case ^mu.Command_Icon:
				draw_icon(&ui_ctx, v.id, v.rect, v.color)
			case ^mu.Command_Clip:
				clip(&ui_ctx, v.rect)
			case ^mu.Command_Jump:
				unreachable()
			}
		}

		cmdbuf := sdl3.AcquireGPUCommandBuffer(gpu)
		defer must(sdl3.SubmitGPUCommandBuffer(cmdbuf))

		width, height: u32
		swapchain_texture: ^sdl3.GPUTexture
		must(sdl3.WaitAndAcquireGPUSwapchainTexture(cmdbuf, window, &swapchain_texture, &width, &height))

		if width != u32(canvas.size.x) || height != u32(canvas.size.y) {
			canvas_resize(&canvas, gpu, width, height)
		}

		if swapchain_texture != nil {
			if canvas.dirty {
				recompute(cmdbuf, gpu, compute_pipeline, &canvas, &params)
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
				load_op = .LOAD,
			})

			ui_draw(cmdbuf, &ui_ctx, gpu, width, height, &sdl3.GPUColorTargetInfo{
				texture = swapchain_texture,
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

recompute :: proc(
	cmdbuff: ^sdl3.GPUCommandBuffer,
	gpu: ^sdl3.GPUDevice,
	compute_pipeline: ^sdl3.GPUComputePipeline,
	canvas: ^Canvas,
	params: ^Params,
) {
	canvas.dirty = false
	sdl3.PushGPUComputeUniformData(cmdbuff, 0, &canvas.view_box, size_of(canvas.view_box))
	sdl3.PushGPUComputeUniformData(cmdbuff, 1, params, size_of(params))

	texture_binding := sdl3.GPUStorageTextureReadWriteBinding{
		texture = canvas.texture,
	}
	compute_pass := must(sdl3.BeginGPUComputePass(cmdbuff, &texture_binding, 1, nil, 0))
	defer sdl3.EndGPUComputePass(compute_pass)

	sdl3.BindGPUComputePipeline(compute_pass, compute_pipeline)
	sdl3.BindGPUComputeStorageBuffers(compute_pass, 0, &canvas.palette_buffer, 1)
	sdl3.DispatchGPUCompute(
		compute_pass,
		(u32(canvas.size.x) + CELL_SIZE - 1)/CELL_SIZE,
		(u32(canvas.size.y) + CELL_SIZE - 1)/CELL_SIZE,
		1,
	)
}

canvas_resize :: proc(canvas: ^Canvas, gpu: ^sdl3.GPUDevice, width, height: u32) {
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
		usage = {.SAMPLER, .COMPUTE_STORAGE_WRITE},
		width = width,
		height = height,
		layer_count_or_depth = 1,
		num_levels = 1,
	}))
}

pan :: proc(canvas: ^Canvas, delta: m.dvec2) {
	canvas.min_bounds -= delta
	canvas.max_bounds -= delta
	canvas.dirty = true
}

zoom :: proc(canvas: ^Canvas, pivot: m.dvec2, scale: f64) {
	zoom_around(&canvas.min_bounds, pivot, scale)
	zoom_around(&canvas.max_bounds, pivot, scale)
	canvas.dirty = true
}

zoom_around :: proc(v: ^m.dvec2, pivot: m.dvec2, zoom: f64) {
	v^ -= pivot
	v^ *= zoom
	v^ += pivot
}

screen_to_world :: proc(c: Canvas, x, y: f32) -> m.dvec2 {
	v := m.dvec2{f64(x), f64(y)}
	return v * (c.max_bounds - c.min_bounds) / c.size + c.min_bounds
}

canvas_init :: proc(canvas: ^Canvas, gpu: ^sdl3.GPUDevice, size: m.dvec2, vb: View_Box) {
	canvas.view_box = vb
	canvas.size = size
	canvas_resize(canvas, gpu, u32(size.x), u32(size.y))

	canvas.palette_buffer = must(sdl3.CreateGPUBuffer(gpu, sdl3.GPUBufferCreateInfo{
		usage = {.COMPUTE_STORAGE_READ},
		size = size_of(COLORMAP),
	}))

	cmdbuff := sdl3.AcquireGPUCommandBuffer(gpu)
	defer must(sdl3.SubmitGPUCommandBuffer(cmdbuff))

	upload_to_gpu_buffer(cmdbuff, gpu, {slice.to_bytes(COLORMAP[:]), canvas.palette_buffer})
}

// https://github.com/pengnam/cOLORMAPs-from-MatPlotLib2.0/blob/master/inferno.m
@(rodata)
COLORMAP := [256][4]f32{
	{0.001462,0.000466,0.013866,1},
	{0.002267,0.001270,0.018570,1},
	{0.003299,0.002249,0.024239,1},
	{0.004547,0.003392,0.030909,1},
	{0.006006,0.004692,0.038558,1},
	{0.007676,0.006136,0.046836,1},
	{0.009561,0.007713,0.055143,1},
	{0.011663,0.009417,0.063460,1},
	{0.013995,0.011225,0.071862,1},
	{0.016561,0.013136,0.080282,1},
	{0.019373,0.015133,0.088767,1},
	{0.022447,0.017199,0.097327,1},
	{0.025793,0.019331,0.105930,1},
	{0.029432,0.021503,0.114621,1},
	{0.033385,0.023702,0.123397,1},
	{0.037668,0.025921,0.132232,1},
	{0.042253,0.028139,0.141141,1},
	{0.046915,0.030324,0.150164,1},
	{0.051644,0.032474,0.159254,1},
	{0.056449,0.034569,0.168414,1},
	{0.061340,0.036590,0.177642,1},
	{0.066331,0.038504,0.186962,1},
	{0.071429,0.040294,0.196354,1},
	{0.076637,0.041905,0.205799,1},
	{0.081962,0.043328,0.215289,1},
	{0.087411,0.044556,0.224813,1},
	{0.092990,0.045583,0.234358,1},
	{0.098702,0.046402,0.243904,1},
	{0.104551,0.047008,0.253430,1},
	{0.110536,0.047399,0.262912,1},
	{0.116656,0.047574,0.272321,1},
	{0.122908,0.047536,0.281624,1},
	{0.129285,0.047293,0.290788,1},
	{0.135778,0.046856,0.299776,1},
	{0.142378,0.046242,0.308553,1},
	{0.149073,0.045468,0.317085,1},
	{0.155850,0.044559,0.325338,1},
	{0.162689,0.043554,0.333277,1},
	{0.169575,0.042489,0.340874,1},
	{0.176493,0.041402,0.348111,1},
	{0.183429,0.040329,0.354971,1},
	{0.190367,0.039309,0.361447,1},
	{0.197297,0.038400,0.367535,1},
	{0.204209,0.037632,0.373238,1},
	{0.211095,0.037030,0.378563,1},
	{0.217949,0.036615,0.383522,1},
	{0.224763,0.036405,0.388129,1},
	{0.231538,0.036405,0.392400,1},
	{0.238273,0.036621,0.396353,1},
	{0.244967,0.037055,0.400007,1},
	{0.251620,0.037705,0.403378,1},
	{0.258234,0.038571,0.406485,1},
	{0.264810,0.039647,0.409345,1},
	{0.271347,0.040922,0.411976,1},
	{0.277850,0.042353,0.414392,1},
	{0.284321,0.043933,0.416608,1},
	{0.290763,0.045644,0.418637,1},
	{0.297178,0.047470,0.420491,1},
	{0.303568,0.049396,0.422182,1},
	{0.309935,0.051407,0.423721,1},
	{0.316282,0.053490,0.425116,1},
	{0.322610,0.055634,0.426377,1},
	{0.328921,0.057827,0.427511,1},
	{0.335217,0.060060,0.428524,1},
	{0.341500,0.062325,0.429425,1},
	{0.347771,0.064616,0.430217,1},
	{0.354032,0.066925,0.430906,1},
	{0.360284,0.069247,0.431497,1},
	{0.366529,0.071579,0.431994,1},
	{0.372768,0.073915,0.432400,1},
	{0.379001,0.076253,0.432719,1},
	{0.385228,0.078591,0.432955,1},
	{0.391453,0.080927,0.433109,1},
	{0.397674,0.083257,0.433183,1},
	{0.403894,0.085580,0.433179,1},
	{0.410113,0.087896,0.433098,1},
	{0.416331,0.090203,0.432943,1},
	{0.422549,0.092501,0.432714,1},
	{0.428768,0.094790,0.432412,1},
	{0.434987,0.097069,0.432039,1},
	{0.441207,0.099338,0.431594,1},
	{0.447428,0.101597,0.431080,1},
	{0.453651,0.103848,0.430498,1},
	{0.459875,0.106089,0.429846,1},
	{0.466100,0.108322,0.429125,1},
	{0.472328,0.110547,0.428334,1},
	{0.478558,0.112764,0.427475,1},
	{0.484789,0.114974,0.426548,1},
	{0.491022,0.117179,0.425552,1},
	{0.497257,0.119379,0.424488,1},
	{0.503493,0.121575,0.423356,1},
	{0.509730,0.123769,0.422156,1},
	{0.515967,0.125960,0.420887,1},
	{0.522206,0.128150,0.419549,1},
	{0.528444,0.130341,0.418142,1},
	{0.534683,0.132534,0.416667,1},
	{0.540920,0.134729,0.415123,1},
	{0.547157,0.136929,0.413511,1},
	{0.553392,0.139134,0.411829,1},
	{0.559624,0.141346,0.410078,1},
	{0.565854,0.143567,0.408258,1},
	{0.572081,0.145797,0.406369,1},
	{0.578304,0.148039,0.404411,1},
	{0.584521,0.150294,0.402385,1},
	{0.590734,0.152563,0.400290,1},
	{0.596940,0.154848,0.398125,1},
	{0.603139,0.157151,0.395891,1},
	{0.609330,0.159474,0.393589,1},
	{0.615513,0.161817,0.391219,1},
	{0.621685,0.164184,0.388781,1},
	{0.627847,0.166575,0.386276,1},
	{0.633998,0.168992,0.383704,1},
	{0.640135,0.171438,0.381065,1},
	{0.646260,0.173914,0.378359,1},
	{0.652369,0.176421,0.375586,1},
	{0.658463,0.178962,0.372748,1},
	{0.664540,0.181539,0.369846,1},
	{0.670599,0.184153,0.366879,1},
	{0.676638,0.186807,0.363849,1},
	{0.682656,0.189501,0.360757,1},
	{0.688653,0.192239,0.357603,1},
	{0.694627,0.195021,0.354388,1},
	{0.700576,0.197851,0.351113,1},
	{0.706500,0.200728,0.347777,1},
	{0.712396,0.203656,0.344383,1},
	{0.718264,0.206636,0.340931,1},
	{0.724103,0.209670,0.337424,1},
	{0.729909,0.212759,0.333861,1},
	{0.735683,0.215906,0.330245,1},
	{0.741423,0.219112,0.326576,1},
	{0.747127,0.222378,0.322856,1},
	{0.752794,0.225706,0.319085,1},
	{0.758422,0.229097,0.315266,1},
	{0.764010,0.232554,0.311399,1},
	{0.769556,0.236077,0.307485,1},
	{0.775059,0.239667,0.303526,1},
	{0.780517,0.243327,0.299523,1},
	{0.785929,0.247056,0.295477,1},
	{0.791293,0.250856,0.291390,1},
	{0.796607,0.254728,0.287264,1},
	{0.801871,0.258674,0.283099,1},
	{0.807082,0.262692,0.278898,1},
	{0.812239,0.266786,0.274661,1},
	{0.817341,0.270954,0.270390,1},
	{0.822386,0.275197,0.266085,1},
	{0.827372,0.279517,0.261750,1},
	{0.832299,0.283913,0.257383,1},
	{0.837165,0.288385,0.252988,1},
	{0.841969,0.292933,0.248564,1},
	{0.846709,0.297559,0.244113,1},
	{0.851384,0.302260,0.239636,1},
	{0.855992,0.307038,0.235133,1},
	{0.860533,0.311892,0.230606,1},
	{0.865006,0.316822,0.226055,1},
	{0.869409,0.321827,0.221482,1},
	{0.873741,0.326906,0.216886,1},
	{0.878001,0.332060,0.212268,1},
	{0.882188,0.337287,0.207628,1},
	{0.886302,0.342586,0.202968,1},
	{0.890341,0.347957,0.198286,1},
	{0.894305,0.353399,0.193584,1},
	{0.898192,0.358911,0.188860,1},
	{0.902003,0.364492,0.184116,1},
	{0.905735,0.370140,0.179350,1},
	{0.909390,0.375856,0.174563,1},
	{0.912966,0.381636,0.169755,1},
	{0.916462,0.387481,0.164924,1},
	{0.919879,0.393389,0.160070,1},
	{0.923215,0.399359,0.155193,1},
	{0.926470,0.405389,0.150292,1},
	{0.929644,0.411479,0.145367,1},
	{0.932737,0.417627,0.140417,1},
	{0.935747,0.423831,0.135440,1},
	{0.938675,0.430091,0.130438,1},
	{0.941521,0.436405,0.125409,1},
	{0.944285,0.442772,0.120354,1},
	{0.946965,0.449191,0.115272,1},
	{0.949562,0.455660,0.110164,1},
	{0.952075,0.462178,0.105031,1},
	{0.954506,0.468744,0.099874,1},
	{0.956852,0.475356,0.094695,1},
	{0.959114,0.482014,0.089499,1},
	{0.961293,0.488716,0.084289,1},
	{0.963387,0.495462,0.079073,1},
	{0.965397,0.502249,0.073859,1},
	{0.967322,0.509078,0.068659,1},
	{0.969163,0.515946,0.063488,1},
	{0.970919,0.522853,0.058367,1},
	{0.972590,0.529798,0.053324,1},
	{0.974176,0.536780,0.048392,1},
	{0.975677,0.543798,0.043618,1},
	{0.977092,0.550850,0.039050,1},
	{0.978422,0.557937,0.034931,1},
	{0.979666,0.565057,0.031409,1},
	{0.980824,0.572209,0.028508,1},
	{0.981895,0.579392,0.026250,1},
	{0.982881,0.586606,0.024661,1},
	{0.983779,0.593849,0.023770,1},
	{0.984591,0.601122,0.023606,1},
	{0.985315,0.608422,0.024202,1},
	{0.985952,0.615750,0.025592,1},
	{0.986502,0.623105,0.027814,1},
	{0.986964,0.630485,0.030908,1},
	{0.987337,0.637890,0.034916,1},
	{0.987622,0.645320,0.039886,1},
	{0.987819,0.652773,0.045581,1},
	{0.987926,0.660250,0.051750,1},
	{0.987945,0.667748,0.058329,1},
	{0.987874,0.675267,0.065257,1},
	{0.987714,0.682807,0.072489,1},
	{0.987464,0.690366,0.079990,1},
	{0.987124,0.697944,0.087731,1},
	{0.986694,0.705540,0.095694,1},
	{0.986175,0.713153,0.103863,1},
	{0.985566,0.720782,0.112229,1},
	{0.984865,0.728427,0.120785,1},
	{0.984075,0.736087,0.129527,1},
	{0.983196,0.743758,0.138453,1},
	{0.982228,0.751442,0.147565,1},
	{0.981173,0.759135,0.156863,1},
	{0.980032,0.766837,0.166353,1},
	{0.978806,0.774545,0.176037,1},
	{0.977497,0.782258,0.185923,1},
	{0.976108,0.789974,0.196018,1},
	{0.974638,0.797692,0.206332,1},
	{0.973088,0.805409,0.216877,1},
	{0.971468,0.813122,0.227658,1},
	{0.969783,0.820825,0.238686,1},
	{0.968041,0.828515,0.249972,1},
	{0.966243,0.836191,0.261534,1},
	{0.964394,0.843848,0.273391,1},
	{0.962517,0.851476,0.285546,1},
	{0.960626,0.859069,0.298010,1},
	{0.958720,0.866624,0.310820,1},
	{0.956834,0.874129,0.323974,1},
	{0.954997,0.881569,0.337475,1},
	{0.953215,0.888942,0.351369,1},
	{0.951546,0.896226,0.365627,1},
	{0.950018,0.903409,0.380271,1},
	{0.948683,0.910473,0.395289,1},
	{0.947594,0.917399,0.410665,1},
	{0.946809,0.924168,0.426373,1},
	{0.946392,0.930761,0.442367,1},
	{0.946403,0.937159,0.458592,1},
	{0.946903,0.943348,0.474970,1},
	{0.947937,0.949318,0.491426,1},
	{0.949545,0.955063,0.507860,1},
	{0.951740,0.960587,0.524203,1},
	{0.954529,0.965896,0.540361,1},
	{0.957896,0.971003,0.556275,1},
	{0.961812,0.975924,0.571925,1},
	{0.966249,0.980678,0.587206,1},
	{0.971162,0.985282,0.602154,1},
	{0.976511,0.989753,0.616760,1},
	{0.982257,0.994109,0.631017,1},
	{0.988362,0.998364,0.644924,1},
}

Vertex :: struct {
	pos: [2]f32,
	tex: [2]f32,
	col: mu.Color,
}

UI_Context :: struct {
	pipeline: ^sdl3.GPUGraphicsPipeline,
	vertices: [dynamic]Vertex,
	indices: [dynamic]u16,
	vbuf: ^sdl3.GPUBuffer,
	ibuf: ^sdl3.GPUBuffer,
	buf_capacity: u32,
	indices_flushed: u32,
	clip_rect: Maybe(mu.Rect),
	draw_calls: [dynamic]Draw_Call,
	atlas_sampler: sdl3.GPUTextureSamplerBinding,
}

Draw_Call :: struct {
	base_index: u32,
	num_indices: u32,
	clip: Maybe(mu.Rect),
}

push_quad :: proc(ctx: ^UI_Context, dst, src: mu.Rect, color: mu.Color) {
	u0 := f32(src.x) / f32(mu.DEFAULT_ATLAS_WIDTH)
	v0 := f32(src.y) / f32(mu.DEFAULT_ATLAS_HEIGHT)
	u1 := f32(src.x + src.w) / f32(mu.DEFAULT_ATLAS_WIDTH)
	v1 := f32(src.y + src.h) / f32(mu.DEFAULT_ATLAS_HEIGHT)
	x0 := f32(dst.x)
	y0 := f32(dst.y)
	x1 := f32(dst.x + dst.w)
	y1 := f32(dst.y + dst.h)

	base_idx := u16(len(ctx.vertices))
	append(&ctx.vertices,
		Vertex{pos = {x0, y0}, tex = {u0, v0}, col = color}, // top left
		Vertex{pos = {x0, y1}, tex = {u0, v1}, col = color}, // bottom left
		Vertex{pos = {x1, y1}, tex = {u1, v1}, col = color}, // bottom right
		Vertex{pos = {x1, y0}, tex = {u1, v0}, col = color}, // top right
	)
	append(&ctx.indices,
		base_idx + 0,
		base_idx + 1,
		base_idx + 2,
		base_idx + 0,
		base_idx + 2,
		base_idx + 3,
	)
}

draw_rect :: proc(ctx: ^UI_Context, rect: mu.Rect, color: mu.Color) {
	push_quad(ctx, rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], color)
}

flush :: proc(ctx: ^UI_Context) {
	curr_index := u32(len(ctx.indices))
	append(&ctx.draw_calls, Draw_Call{
		base_index = ctx.indices_flushed,
		num_indices = curr_index - ctx.indices_flushed,
		clip = ctx.clip_rect,
	})
	ctx.indices_flushed = curr_index
}

clip :: proc(ctx: ^UI_Context, rect: mu.Rect) {
	flush(ctx)
	ctx.clip_rect = rect
}

draw_icon :: proc(ctx: ^UI_Context, id: mu.Icon, rect: mu.Rect, color: mu.Color) {
	src := mu.default_atlas[id]
	x := rect.x + (rect.w - src.w) / 2
	y := rect.y + (rect.h - src.h) / 2
	push_quad(ctx, {x, y, src.w, src.h}, src, color)
}

draw_text :: proc(ctx: ^UI_Context, text: string, pos: mu.Vec2, color: mu.Color) {
	dst := mu.Rect{ pos.x, pos.y, 0, 0 }
	for r in text {
		chr := min(int(r), 127)
		src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + chr]
		dst.w = src.w
		dst.h = src.h
		push_quad(ctx, dst, src, color)
		dst.x += dst.w
	}
}

ui_context_reset :: proc(ui_ctx: ^UI_Context) {
	clear(&ui_ctx.vertices)
	clear(&ui_ctx.indices)
	clear(&ui_ctx.draw_calls)
	ui_ctx.clip_rect = nil
	ui_ctx.indices_flushed = 0
}

ui_context_init :: proc(ui_ctx: ^UI_Context, gpu: ^sdl3.GPUDevice, window: ^sdl3.Window) {
	vert_source := #load("./shader.vert.spv")
	vert_shader := must(sdl3.CreateGPUShader(gpu, sdl3.GPUShaderCreateInfo{
		code_size = len(vert_source),
		code = raw_data(vert_source),
		entrypoint = "main",
		format = {.SPIRV},
		stage = .VERTEX,
		num_uniform_buffers = 1,
	}))
	defer sdl3.ReleaseGPUShader(gpu, vert_shader)

	frag_source := #load("./shader.frag.spv")
	frag_shader := must(sdl3.CreateGPUShader(gpu, sdl3.GPUShaderCreateInfo{
		code_size = len(frag_source),
		code = raw_data(frag_source),
		entrypoint = "main",
		format = {.SPIRV},
		stage = .FRAGMENT,
		num_samplers = 1,
	}))
	defer sdl3.ReleaseGPUShader(gpu, frag_shader)

	rgba8_pixels := make([][4]u8, len(mu.default_atlas_alpha), context.temp_allocator)
	for &t in soa_zip(alpha=mu.default_atlas_alpha[:], pixel=rgba8_pixels) {
		t.pixel.rgb = 0xff
		t.pixel.a = t.alpha
	}

	ui_ctx.atlas_sampler = sdl3.GPUTextureSamplerBinding{
		texture = must(sdl3.CreateGPUTexture(gpu, sdl3.GPUTextureCreateInfo{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = mu.DEFAULT_ATLAS_WIDTH,
			height = mu.DEFAULT_ATLAS_HEIGHT,
			layer_count_or_depth = 1,
			num_levels = 1,
		})),
		sampler = must(sdl3.CreateGPUSampler(gpu, sdl3.GPUSamplerCreateInfo{
			min_filter = .NEAREST,
			mag_filter = .NEAREST,
		})),
	}

	{
		cmdbuff := sdl3.AcquireGPUCommandBuffer(gpu)
		defer must(sdl3.SubmitGPUCommandBuffer(cmdbuff))

		tbuf := must(sdl3.CreateGPUTransferBuffer(gpu, sdl3.GPUTransferBufferCreateInfo{
			usage = .UPLOAD,
			size = u32(size_of(rgba8_pixels[0]) * len(rgba8_pixels)),
		}))
		defer sdl3.ReleaseGPUTransferBuffer(gpu, tbuf)

		tmem := cast([^][4]u8) sdl3.MapGPUTransferBuffer(gpu, tbuf, true)
		copy(tmem[:len(rgba8_pixels)], rgba8_pixels)
		sdl3.UnmapGPUTransferBuffer(gpu, tbuf)

		copy_pass := sdl3.BeginGPUCopyPass(cmdbuff)
		defer sdl3.EndGPUCopyPass(copy_pass)

		sdl3.UploadToGPUTexture(copy_pass,
			sdl3.GPUTextureTransferInfo{
				transfer_buffer = tbuf,
				pixels_per_row = mu.DEFAULT_ATLAS_WIDTH,
				rows_per_layer = mu.DEFAULT_ATLAS_HEIGHT,
			},
			sdl3.GPUTextureRegion{
				texture = ui_ctx.atlas_sampler.texture,
				w = mu.DEFAULT_ATLAS_WIDTH,
				h = mu.DEFAULT_ATLAS_HEIGHT,
				d = 1,
			},
			true,
		)
	}

	attributes := []sdl3.GPUVertexAttribute{
		{
			location = 0,
			format = .FLOAT2,
			offset = u32(offset_of(Vertex, pos)),
		},
		{
			location = 1,
			format = .FLOAT2,
			offset = u32(offset_of(Vertex, tex)),
		},
		{
			location = 2,
			format = .UBYTE4_NORM,
			offset = u32(offset_of(Vertex, col)),
		},
	}

	ui_ctx.pipeline = must(sdl3.CreateGPUGraphicsPipeline(gpu, sdl3.GPUGraphicsPipelineCreateInfo{
		vertex_shader = vert_shader,
		fragment_shader = frag_shader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = sdl3.GPUVertexInputState{
			num_vertex_buffers = 1,
			vertex_buffer_descriptions = &sdl3.GPUVertexBufferDescription{
				pitch = size_of(Vertex),
				input_rate = .VERTEX,
			},
			num_vertex_attributes = u32(len(attributes)),
			vertex_attributes = raw_data(attributes),
		},
		rasterizer_state = sdl3.GPURasterizerState{
			cull_mode = .BACK,
		},
		target_info = sdl3.GPUGraphicsPipelineTargetInfo{
			num_color_targets = 1,
			color_target_descriptions = &sdl3.GPUColorTargetDescription{
				format = sdl3.GetGPUSwapchainTextureFormat(gpu, window),
				blend_state = sdl3.GPUColorTargetBlendState{
					enable_blend = true,
					alpha_blend_op = .ADD,
					src_alpha_blendfactor = .ONE,
					dst_alpha_blendfactor = .ZERO,
					color_blend_op = .ADD,
					src_color_blendfactor = .SRC_ALPHA,
					dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
				},
			},
		},
	}))
}

ui_draw :: proc(cmdbuf: ^sdl3.GPUCommandBuffer, ui_ctx: ^UI_Context, gpu: ^sdl3.GPUDevice, width, height: u32, color_target: ^sdl3.GPUColorTargetInfo) {
	flush(ui_ctx)
	// Upload vertex and index data to the GPU
	if len(ui_ctx.indices) > 0 {
		assert(len(ui_ctx.indices) <= int(max(u16)))

		num_quads := len(ui_ctx.indices)/6
		if num_quads > int(ui_ctx.buf_capacity) {
			for ui_ctx.buf_capacity == 0 {
				ui_ctx.buf_capacity = 256
			}
			for ui_ctx.buf_capacity < u32(num_quads) {
				ui_ctx.buf_capacity *= 2
			}
			fmt.printfln("resizing buffers (new cap: {})", ui_ctx.buf_capacity)

			sdl3.ReleaseGPUBuffer(gpu, ui_ctx.vbuf)
			sdl3.ReleaseGPUBuffer(gpu, ui_ctx.ibuf)

			ui_ctx.vbuf = must(sdl3.CreateGPUBuffer(gpu, sdl3.GPUBufferCreateInfo{
				usage = {.VERTEX},
				size = 4 * u32(ui_ctx.buf_capacity) * size_of(Vertex),
			}))
			ui_ctx.ibuf = must(sdl3.CreateGPUBuffer(gpu, sdl3.GPUBufferCreateInfo{
				usage = {.INDEX},
				size = 6 * u32(ui_ctx.buf_capacity) * size_of(u16),
			}))
		}

		upload_to_gpu_buffer(cmdbuf, gpu,
			{slice.to_bytes(ui_ctx.vertices[:]), ui_ctx.vbuf},
			{slice.to_bytes(ui_ctx.indices[:]),  ui_ctx.ibuf},
		)
	}

	mvp := m.mat4Ortho3d(0, f32(width), f32(height), 0, 0, 1)
	sdl3.PushGPUVertexUniformData(cmdbuf, 0, &mvp, size_of(mvp))

	render_pass := sdl3.BeginGPURenderPass(cmdbuf, color_target, 1, nil)
	sdl3.BindGPUGraphicsPipeline(render_pass, ui_ctx.pipeline)
	sdl3.BindGPUFragmentSamplers(render_pass, 0, &ui_ctx.atlas_sampler, 1)
	sdl3.BindGPUVertexBuffers(render_pass, 0, &sdl3.GPUBufferBinding{buffer = ui_ctx.vbuf}, 1)
	sdl3.BindGPUIndexBuffer(render_pass, sdl3.GPUBufferBinding{buffer = ui_ctx.ibuf}, ._16BIT)

	for dc in ui_ctx.draw_calls {
		if r, ok := dc.clip.(mu.Rect); ok {
			sdl3.SetGPUScissor(render_pass, sdl3.Rect(r))
		}
		sdl3.DrawGPUIndexedPrimitives(render_pass, dc.num_indices, 1, dc.base_index, 0, 0)
	}

	sdl3.EndGPURenderPass(render_pass)
	ui_context_reset(ui_ctx)
}

Transfer_Command :: struct {
	data: []byte,
	buffer: ^sdl3.GPUBuffer,
}

upload_to_gpu_buffer :: proc(cmdbuf: ^sdl3.GPUCommandBuffer, gpu: ^sdl3.GPUDevice, commands: ..Transfer_Command) {
	transfer_size: u32
	for desc in commands {
		transfer_size += u32(len(desc.data))
	}

	tbuf := must(sdl3.CreateGPUTransferBuffer(gpu, sdl3.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size = transfer_size,
	}))
	defer sdl3.ReleaseGPUTransferBuffer(gpu, tbuf)

	tmem := cast([^]byte) sdl3.MapGPUTransferBuffer(gpu, tbuf, true)
	mem_offset: int
	for desc in commands {
		mem_offset += copy(tmem[mem_offset:][:len(desc.data)], desc.data)
	}
	sdl3.UnmapGPUTransferBuffer(gpu, tbuf)

	offset: u32
	copy_pass := sdl3.BeginGPUCopyPass(cmdbuf)
	for desc in commands {
		size := u32(len(desc.data))
		src := sdl3.GPUTransferBufferLocation{transfer_buffer = tbuf, offset = offset}
		sdl3.UploadToGPUBuffer(copy_pass, src, {buffer = desc.buffer, size = size}, false)
		offset += size
	}
	sdl3.EndGPUCopyPass(copy_pass)
}

mu_input_key :: proc(mu_ctx: ^mu.Context, ev: sdl3.KeyboardEvent) {
	input := ev.down ? mu.input_key_down : mu.input_key_up
	#partial switch ev.scancode {
	case .LSHIFT:    input(mu_ctx, .SHIFT)
	case .RSHIFT:    input(mu_ctx, .SHIFT)
	case .LCTRL:     input(mu_ctx, .CTRL)
	case .RCTRL:     input(mu_ctx, .CTRL)
	case .LALT:      input(mu_ctx, .ALT)
	case .RALT:      input(mu_ctx, .ALT)
	case .RETURN:    input(mu_ctx, .RETURN)
	case .KP_ENTER:  input(mu_ctx, .RETURN)
	case .BACKSPACE: input(mu_ctx, .BACKSPACE)
	case .LEFT:      input(mu_ctx, .LEFT)
	case .RIGHT:     input(mu_ctx, .RIGHT)
	case .HOME:      input(mu_ctx, .HOME)
	case .END:       input(mu_ctx, .END)
	case .DELETE:    input(mu_ctx, .DELETE)
	case .A:         input(mu_ctx, .A)
	case .X:         input(mu_ctx, .X)
	case .C:         input(mu_ctx, .C)
	case .V:         input(mu_ctx, .V)
	}
}

mu_input_mouse_button :: proc(mu_ctx: ^mu.Context, ev: sdl3.MouseButtonEvent) {
	input := ev.down ? mu.input_mouse_down : mu.input_mouse_up
	switch ev.button {
	case sdl3.BUTTON_LEFT:   input(mu_ctx, i32(ev.x), i32(ev.y), .LEFT)
	case sdl3.BUTTON_RIGHT:  input(mu_ctx, i32(ev.x), i32(ev.y), .RIGHT)
	case sdl3.BUTTON_MIDDLE: input(mu_ctx, i32(ev.x), i32(ev.y), .MIDDLE)
	}
}
