use super::{BrowserCapture, BrowserEvent, BrowserSurface, model::Presentation};
use crate::{
    composer::{ComposerInput, ComposerInputEvent},
    theme::Theme,
};
use gpui::{prelude::*, *};
use std::{cell::Cell, rc::Rc, sync::Arc};

#[derive(Clone, Copy, PartialEq)]
enum CaptureTool {
    Elements,
    Area,
}

#[derive(Clone, serde::Deserialize)]
struct PageElement {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    tag: String,
    selector: String,
    text: String,
    depth: usize,
}

impl PageElement {
    fn rect(&self) -> Bounds<f32> {
        Bounds::new(point(self.x, self.y), size(self.width, self.height))
    }
    fn valid(&self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|value| value.is_finite())
            && self.x >= 0.
            && self.y >= 0.
            && self.width > 0.
            && self.height > 0.
            && self.x + self.width <= 1.001
            && self.y + self.height <= 1.001
    }
}

#[derive(Clone)]
struct Mark {
    rect: Bounds<f32>,
    element: Option<PageElement>,
    comment: String,
}

pub(super) struct CaptureDraft {
    id: String,
    image: Arc<RenderImage>,
    url: String,
    title: String,
    viewport: (u32, u32),
    bounds: Rc<Cell<Bounds<Pixels>>>,
    tool: CaptureTool,
    start: Option<Point<f32>>,
    selection: Option<Bounds<f32>>,
    marks: Vec<Mark>,
    selected: Option<usize>,
    picking_next: bool,
    hovered: Option<usize>,
    elements: Vec<PageElement>,
    elements_loading: bool,
    error: Option<String>,
    general_comment: String,
    input: Entity<ComposerInput>,
    _input_events: Subscription,
}

impl CaptureDraft {
    fn point(&self, position: Point<Pixels>) -> Point<f32> {
        let bounds = self.bounds.get();
        point(
            (f32::from(position.x - bounds.left()) / f32::from(bounds.size.width).max(1.))
                .clamp(0., 1.),
            (f32::from(position.y - bounds.top()) / f32::from(bounds.size.height).max(1.))
                .clamp(0., 1.),
        )
    }

    fn element_at(&self, position: Point<f32>) -> Option<usize> {
        self.elements
            .iter()
            .enumerate()
            .filter(|(_, element)| element.rect().contains(&position))
            .min_by(|(_, a), (_, b)| {
                (a.width * a.height)
                    .total_cmp(&(b.width * b.height))
                    .then(b.depth.cmp(&a.depth))
            })
            .map(|(index, _)| index)
    }

    fn save_comment(&mut self, cx: &App) {
        let text = self.input.read(cx).text().to_owned();
        if let Some(mark) = self.selected.and_then(|index| self.marks.get_mut(index)) {
            mark.comment = text;
        } else {
            self.general_comment = text;
        }
    }

    fn select(&mut self, index: Option<usize>, window: &mut Window, cx: &mut App) {
        self.save_comment(cx);
        self.selected = index;
        self.picking_next = false;
        let text = index
            .and_then(|index| self.marks.get(index))
            .map(|mark| mark.comment.clone())
            .unwrap_or_else(|| self.general_comment.clone());
        self.input.update(cx, |input, cx| input.set_text(text, cx));
        window.focus(&self.input.focus_handle(cx), cx);
    }

    fn add_mark(
        &mut self,
        rect: Bounds<f32>,
        element: Option<PageElement>,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.save_comment(cx);
        self.marks.push(Mark {
            rect,
            element,
            comment: String::new(),
        });
        self.selected = Some(self.marks.len() - 1);
        self.picking_next = false;
        self.input.update(cx, |input, cx| input.set_text("", cx));
        window.focus(&self.input.focus_handle(cx), cx);
    }

    fn texts(&self) -> (String, String) {
        let mut context = String::from(
            "Numbered marks in the screenshot correspond to the following feedback.\n",
        );
        let mut message = self.general_comment.trim().to_owned();
        for (index, mark) in self.marks.iter().enumerate() {
            let number = index + 1;
            context.push_str(&format!(
                "\nMark {number}: x={:.0}, y={:.0}, width={:.0}, height={:.0} CSS pixels\n",
                mark.rect.left() * self.viewport.0 as f32,
                mark.rect.top() * self.viewport.1 as f32,
                mark.rect.size.width * self.viewport.0 as f32,
                mark.rect.size.height * self.viewport.1 as f32
            ));
            if let Some(element) = &mark.element {
                context.push_str(&format!(
                    "Element: <{}>\nSelector: {}\nVisible text: {}\n",
                    element.tag, element.selector, element.text
                ));
            }
            if !mark.comment.trim().is_empty() {
                context.push_str(&format!("Comment: {}\n", mark.comment.trim()));
                if !message.is_empty() {
                    message.push('\n');
                }
                message.push_str(&format!("{number}. {}", mark.comment.trim()));
            }
        }
        if !self.general_comment.trim().is_empty() {
            context.push_str(&format!(
                "\nPage comment: {}\n",
                self.general_comment.trim()
            ));
        }
        (context, message)
    }
}

fn digit_pixels(number: usize) -> Vec<(u32, u32)> {
    const DIGITS: [[u8; 7]; 10] = [
        [14, 17, 19, 21, 25, 17, 14],
        [4, 12, 4, 4, 4, 4, 14],
        [14, 17, 1, 2, 4, 8, 31],
        [30, 1, 1, 14, 1, 1, 30],
        [2, 6, 10, 18, 31, 2, 2],
        [31, 16, 16, 30, 1, 1, 30],
        [14, 16, 16, 30, 17, 17, 14],
        [31, 1, 2, 4, 8, 8, 8],
        [14, 17, 17, 14, 17, 17, 14],
        [14, 17, 17, 15, 1, 1, 14],
    ];
    let mut pixels = Vec::new();
    for (offset, digit) in number.to_string().bytes().enumerate() {
        for (y, row) in DIGITS[(digit - b'0') as usize].iter().enumerate() {
            for x in 0..5 {
                if row & (1 << (4 - x)) != 0 {
                    pixels.push((offset as u32 * 6 + x, y as u32));
                }
            }
        }
    }
    pixels
}

fn encode_image(
    image: Arc<RenderImage>,
    marks: Vec<Mark>,
    viewport_width: u32,
) -> Result<Vec<u8>, String> {
    let dimensions = image.size(0);
    let (width, height) = (
        dimensions.width.0.max(0) as u32,
        dimensions.height.0.max(0) as u32,
    );
    let expected = crate::appshots::validate_capture_dimensions(width, height)
        .map_err(|error| error.to_string())?;
    let bytes = image
        .as_bytes(0)
        .filter(|bytes| bytes.len() == expected)
        .ok_or("The browser frame is unavailable.")?;
    let mut rgba = bytes.to_vec();
    for pixel in rgba.chunks_exact_mut(4) {
        pixel.swap(0, 2);
    }
    let scale = width as f32 / viewport_width.max(1) as f32;
    let stroke = (scale * 3.).round().max(2.) as u32;
    let unit = (scale * 2.).round().max(1.) as u32;
    for (index, mark) in marks.iter().enumerate() {
        let rect = mark.rect;
        let left = ((rect.left() * width as f32).floor() as u32).min(width - 1);
        let top = ((rect.top() * height as f32).floor() as u32).min(height - 1);
        let right = ((rect.right() * width as f32).ceil() as u32)
            .saturating_sub(1)
            .min(width - 1);
        let bottom = ((rect.bottom() * height as f32).ceil() as u32)
            .saturating_sub(1)
            .min(height - 1);
        let mut fill = |x0: u32, y0: u32, x1: u32, y1: u32, color: [u8; 4]| {
            for y in y0.min(height)..y1.min(height) {
                for x in x0.min(width)..x1.min(width) {
                    let offset = (y as usize * width as usize + x as usize) * 4;
                    rgba[offset..offset + 4].copy_from_slice(&color);
                }
            }
        };
        let red = [255, 82, 82, 255];
        fill(left, top, right + 1, (top + stroke).min(bottom + 1), red);
        fill(
            left,
            bottom.saturating_sub(stroke - 1).max(top),
            right + 1,
            bottom + 1,
            red,
        );
        fill(left, top, (left + stroke).min(right + 1), bottom + 1, red);
        fill(
            right.saturating_sub(stroke - 1).max(left),
            top,
            right + 1,
            bottom + 1,
            red,
        );
        let badge_width = ((index + 1).to_string().len() as u32 * 6 + 3) * unit;
        let badge_height = 11 * unit;
        let bx = left.min(width.saturating_sub(badge_width));
        let by = top.min(height.saturating_sub(badge_height));
        fill(bx, by, bx + badge_width, by + badge_height, red);
        for (x, y) in digit_pixels(index + 1) {
            fill(
                bx + (x + 2) * unit,
                by + (y + 2) * unit,
                bx + (x + 3) * unit,
                by + (y + 3) * unit,
                [255; 4],
            );
        }
    }
    crate::appshots::encode_rgba_png(width, height, &rgba, "Browser")
        .map_err(|error| error.to_string())
}

fn paint_mark(
    bounds: Bounds<Pixels>,
    rect: Bounds<f32>,
    number: Option<usize>,
    color: Hsla,
    window: &mut Window,
) {
    let marked = Bounds::new(
        bounds.origin
            + point(
                bounds.size.width * rect.left(),
                bounds.size.height * rect.top(),
            ),
        size(
            bounds.size.width * rect.size.width,
            bounds.size.height * rect.size.height,
        ),
    );
    window.paint_quad(quad(
        marked,
        Corners::default(),
        transparent_black(),
        px(2.),
        color,
        BorderStyle::default(),
    ));
    if let Some(number) = number {
        let width = (number.to_string().len() as f32 * 6. + 3.) * 2.;
        let origin = point(
            marked
                .left()
                .min(bounds.right() - px(width))
                .max(bounds.left()),
            marked
                .top()
                .min(bounds.bottom() - px(22.))
                .max(bounds.top()),
        );
        window.paint_quad(fill(Bounds::new(origin, size(px(width), px(22.))), color));
        for (x, y) in digit_pixels(number) {
            window.paint_quad(fill(
                Bounds::new(
                    origin + point(px((x + 2) as f32 * 2.), px((y + 2) as f32 * 2.)),
                    size(px(2.), px(2.)),
                ),
                rgb(0xffffff),
            ));
        }
    }
}

impl BrowserSurface {
    pub(super) fn can_capture(&self) -> bool {
        !self.page.loading
            && self.page.error.is_none()
            && self
                .native
                .as_ref()
                .is_some_and(|native| native.image.is_some())
    }

    pub(super) fn begin_capture(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.capture.is_some() || self.capture_task.is_some() || !self.can_capture() {
            return;
        }
        let Some(native) = &mut self.native else {
            return;
        };
        let Some(image) = native.image.clone() else {
            return;
        };
        let dimensions = image.size(0);
        if let Err(error) = crate::appshots::validate_capture_dimensions(
            dimensions.width.0.max(0) as u32,
            dimensions.height.0.max(0) as u32,
        ) {
            self.validation = Some(error.to_string());
            cx.notify();
            return;
        }
        let id = uuid::Uuid::new_v4().to_string();
        let input = cx.new(|cx| {
            ComposerInput::with_context("Write what should change…", "BrowserComment", cx)
                .with_text_metrics(13., 20.)
                .with_viewport_height(60.)
        });
        let events = cx.subscribe(&input, |this, _, event, cx| {
            if matches!(event, ComposerInputEvent::Edited)
                && let Some(draft) = &mut this.capture
            {
                draft.save_comment(cx);
                cx.notify();
            }
        });
        let request = serde_json::to_string(&id).unwrap();
        let script = format!(
            "(()=>{{try{{return {{captureId:{request},elements:{}}}}}catch(error){{return {{captureId:{request},error:String(error)}}}}}})()",
            include_str!("capture_elements.js")
        );
        native.command(serde_json::json!({"cmd":"eval","script":script}));
        self.capture = Some(CaptureDraft {
            id,
            image,
            viewport: (
                (dimensions.width.0 as f32 / native.image_scale).round() as u32,
                (dimensions.height.0 as f32 / native.image_scale).round() as u32,
            ),
            url: self.page.url.clone().unwrap_or_default(),
            title: self.page.label(),
            bounds: Default::default(),
            tool: CaptureTool::Elements,
            start: None,
            selection: None,
            marks: Vec::new(),
            selected: None,
            picking_next: true,
            hovered: None,
            elements: Vec::new(),
            elements_loading: true,
            error: None,
            general_comment: String::new(),
            input,
            _input_events: events,
        });
        native.present(Presentation::Hidden);
        window.focus(&self.focus, cx);
        let id = self.capture.as_ref().unwrap().id.clone();
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(4))
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Some(draft) = &mut this.capture
                    && draft.id == id
                    && draft.elements_loading
                {
                    draft.elements_loading = false;
                    draft.error = Some(
                        "Element selection is unavailable on this page. You can still mark areas."
                            .into(),
                    );
                    draft.tool = CaptureTool::Area;
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn capture_elements_received(
        &mut self,
        value: serde_json::Value,
        cx: &mut Context<Self>,
    ) {
        let Some(draft) = &mut self.capture else {
            return;
        };
        if value["captureId"].as_str() != Some(draft.id.as_str()) {
            return;
        }
        draft.elements_loading = false;
        match serde_json::from_value::<Vec<PageElement>>(value["elements"].clone()) {
            Ok(elements) => {
                draft.elements = elements
                    .into_iter()
                    .filter(PageElement::valid)
                    .take(3000)
                    .collect();
                draft.error = None;
                if draft.elements.is_empty() {
                    draft.tool = CaptureTool::Area;
                    draft.error = Some(
                        "No selectable elements in this viewport. Use Area to mark a region."
                            .into(),
                    );
                }
            }
            Err(_) => {
                draft.tool = CaptureTool::Area;
                draft.error =
                    Some("Could not read page elements. Use Area to mark a region.".into());
            }
        }
        cx.notify();
    }

    fn cancel_capture(&mut self, cx: &mut Context<Self>) {
        self.capture_task = None;
        self.capture = None;
        if let Some(native) = &mut self.native {
            native.present(self.presentation);
        }
        cx.notify();
    }

    pub(crate) fn capture_attachment_finished(
        &mut self,
        error: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if let Some(error) = error {
            if let Some(draft) = &mut self.capture {
                draft.error = Some(error);
                draft.input.update(cx, |input, cx| {
                    input.read_only = false;
                    cx.notify();
                });
            }
            cx.notify();
        } else {
            self.cancel_capture(cx);
        }
    }

    fn attach_capture(&mut self, cx: &mut Context<Self>) {
        if self.capture_task.is_some() {
            return;
        }
        let Some(draft) = &mut self.capture else {
            return;
        };
        draft.save_comment(cx);
        draft.input.update(cx, |input, cx| {
            input.read_only = true;
            cx.notify();
        });
        let (feedback, message) = draft.texts();
        let image = draft.image.clone();
        let marks = draft.marks.clone();
        let viewport = draft.viewport;
        let url = draft.url.clone();
        let title = draft.title.clone();
        let work = cx
            .background_executor()
            .spawn(async move { encode_image(image, marks, viewport.0) });
        self.capture_task = Some(cx.spawn(async move |this, cx| {
            let result = work.await;
            let _ = this.update(cx, |this, cx| {
                this.capture_task = None;
                match result {
                    Ok(png) => {
                        cx.emit(BrowserEvent::Capture(BrowserCapture {
                            png,
                            url,
                            title,
                            viewport_width: viewport.0,
                            viewport_height: viewport.1,
                            feedback,
                            message,
                        }));
                    }
                    Err(error) => {
                        if let Some(draft) = &mut this.capture {
                            draft.error = Some(error);
                            draft.input.update(cx, |input, cx| {
                                input.read_only = false;
                                cx.notify();
                            });
                        }
                    }
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn capture_mouse_up(
        &mut self,
        event: &MouseUpEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.capture_task.is_some() {
            return;
        }
        let Some(draft) = &mut self.capture else {
            return;
        };
        let Some(start) = draft.start.take() else {
            return;
        };
        let end = draft.point(event.position);
        if draft.tool == CaptureTool::Elements {
            if !draft.bounds.get().contains(&event.position) {
                return;
            }
            if let Some(element) = draft
                .element_at(end)
                .map(|index| draft.elements[index].clone())
            {
                if let Some(index) = draft.marks.iter().position(|mark| {
                    mark.element
                        .as_ref()
                        .is_some_and(|existing| existing.selector == element.selector)
                }) {
                    draft.select(Some(index), window, cx);
                } else {
                    draft.add_mark(element.rect(), Some(element), window, cx);
                }
            }
        } else {
            let rect = Bounds::new(
                point(start.x.min(end.x), start.y.min(end.y)),
                size((end.x - start.x).abs(), (end.y - start.y).abs()),
            );
            if rect.size.width * f32::from(draft.bounds.get().size.width) >= 5.
                && rect.size.height * f32::from(draft.bounds.get().size.height) >= 5.
            {
                draft.add_mark(rect, None, window, cx);
            } else if let Some(index) = draft
                .marks
                .iter()
                .rposition(|mark| mark.rect.contains(&end))
            {
                draft.select(Some(index), window, cx);
            }
        }
        draft.selection = None;
        draft.hovered = None;
        cx.notify();
    }

    pub(super) fn render_capture(&self, cx: &mut Context<Self>) -> AnyElement {
        let draft = self
            .capture
            .as_ref()
            .expect("capture view requires a draft");
        let theme = Theme::of(cx).clone();
        let image = draft.image.clone();
        let bounds_cell = draft.bounds.clone();
        let selection = draft.selection;
        let marks = draft.marks.clone();
        let selected = draft.selected;
        let hovered = draft
            .hovered
            .and_then(|index| draft.elements.get(index))
            .map(PageElement::rect);
        let busy = self.capture_task.is_some();
        let tool = draft.tool;
        let input = draft.input.clone();
        let control = |id: &'static str, label: SharedString| {
            div()
                .id(id)
                .h(px(30.))
                .px(px(10.))
                .flex_none()
                .flex()
                .items_center()
                .rounded(px(5.))
                .cursor_pointer()
                .role(Role::Button)
                .aria_label(label.clone())
                .border_1()
                .border_color(theme.border)
                .hover(|style| style.bg(theme.surface_raised))
                .child(label)
        };
        let label = selected
            .map(|index| format!("Comment for mark {}", index + 1))
            .unwrap_or_else(|| "Message about this page".into());
        let element_label = selected
            .and_then(|index| draft.marks.get(index))
            .and_then(|mark| mark.element.as_ref())
            .map(|element| format!("<{}> {}", element.tag, element.text));
        let status = if draft.elements_loading {
            "Reading page elements…"
        } else if draft.picking_next && !draft.marks.is_empty() {
            if tool == CaptureTool::Elements {
                "Click another element above. All marks will be added together."
            } else {
                "Draw another area above. All marks will be added together."
            }
        } else if tool == CaptureTool::Elements {
            "Click elements one after another. Comments save automatically."
        } else {
            "Draw areas one after another. Comments save automatically."
        };
        let attach_label: SharedString = if busy {
            "Preparing…".into()
        } else {
            match draft.marks.len() {
                0 => "Add screenshot to chat".into(),
                1 => "Add 1 mark to chat".into(),
                count => format!("Add all {count} to chat").into(),
            }
        };
        let color: Hsla = rgb(0xff5252).into();
        let accent = theme.accent;
        div()
            .id("browser-capture")
            .w_full()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .overflow_hidden()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.text)
            .track_focus(&self.focus)
            .text_size(crate::typography::ui_rems(12.))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    this.cancel_capture(cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex_none()
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        control("browser-capture-elements", "Elements".into())
                            .when(tool == CaptureTool::Elements, |el| {
                                el.bg(theme.surface_raised).border_color(theme.accent)
                            })
                            .when(!busy, |el| {
                                el.on_click(cx.listener(|this, _, window, cx| {
                                    if let Some(draft) = &mut this.capture {
                                        draft.tool = CaptureTool::Elements;
                                        draft.start = None;
                                        draft.selection = None;
                                    }
                                    window.focus(&this.focus, cx);
                                    cx.notify();
                                }))
                            }),
                    )
                    .child(
                        control("browser-capture-area", "Area".into())
                            .when(tool == CaptureTool::Area, |el| {
                                el.bg(theme.surface_raised).border_color(theme.accent)
                            })
                            .when(!busy, |el| {
                                el.on_click(cx.listener(|this, _, window, cx| {
                                    if let Some(draft) = &mut this.capture {
                                        draft.tool = CaptureTool::Area;
                                        draft.hovered = None;
                                        draft.start = None;
                                    }
                                    window.focus(&this.focus, cx);
                                    cx.notify();
                                }))
                            }),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_right()
                            .text_color(theme.text_muted)
                            .child(format!("{} selected", draft.marks.len())),
                    )
                    .child(
                        control("browser-capture-cancel", "Cancel".into())
                            .on_click(cx.listener(|this, _, _, cx| this.cancel_capture(cx))),
                    ),
            )
            .child(
                div()
                    .flex_none()
                    .px(px(12.))
                    .pb(px(8.))
                    .text_size(crate::typography::ui_rems(11.))
                    .text_color(theme.text_muted)
                    .child(status),
            )
            .child(
                div()
                    .id("browser-capture-canvas")
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .overflow_hidden()
                    .cursor_crosshair()
                    .child(
                        canvas(
                            |_, _, _| (),
                            move |bounds, _, window, _| {
                                let dimensions = image.size(0);
                                let scale = (f32::from(bounds.size.width)
                                    / dimensions.width.0 as f32)
                                    .min(f32::from(bounds.size.height) / dimensions.height.0 as f32)
                                    .max(0.);
                                let image_size = size(
                                    px(dimensions.width.0 as f32 * scale),
                                    px(dimensions.height.0 as f32 * scale),
                                );
                                let image_bounds = Bounds::new(
                                    bounds.origin
                                        + point(
                                            (bounds.size.width - image_size.width) / 2.,
                                            (bounds.size.height - image_size.height) / 2.,
                                        ),
                                    image_size,
                                );
                                bounds_cell.set(image_bounds);
                                let _ = window.paint_image(
                                    image_bounds,
                                    Corners::default(),
                                    image.clone(),
                                    0,
                                    false,
                                );
                                if let Some(rect) = hovered {
                                    paint_mark(image_bounds, rect, None, accent, window);
                                }
                                for (index, mark) in marks.iter().enumerate() {
                                    paint_mark(
                                        image_bounds,
                                        mark.rect,
                                        Some(index + 1),
                                        if selected == Some(index) {
                                            accent
                                        } else {
                                            color
                                        },
                                        window,
                                    );
                                }
                                if let Some(rect) = selection {
                                    paint_mark(image_bounds, rect, None, color, window);
                                }
                            },
                        )
                        .absolute()
                        .inset_0(),
                    )
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &MouseDownEvent, window, cx| {
                            if this.capture_task.is_none()
                                && let Some(draft) = &mut this.capture
                                && draft.bounds.get().contains(&event.position)
                            {
                                draft.start = Some(draft.point(event.position));
                                draft.selection = None;
                                window.focus(&this.focus, cx);
                                cx.notify();
                            }
                        }),
                    )
                    .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                        if this.capture_task.is_some() {
                            return;
                        }
                        if let Some(draft) = &mut this.capture {
                            let p = draft.point(event.position);
                            if draft.tool == CaptureTool::Area
                                && let Some(start) = draft.start
                            {
                                draft.selection = Some(Bounds::new(
                                    point(start.x.min(p.x), start.y.min(p.y)),
                                    size((start.x - p.x).abs(), (start.y - p.y).abs()),
                                ));
                                cx.notify();
                            } else if draft.tool == CaptureTool::Elements {
                                let hovered = if draft.bounds.get().contains(&event.position) {
                                    draft.element_at(p)
                                } else {
                                    None
                                };
                                if draft.hovered != hovered {
                                    draft.hovered = hovered;
                                    cx.notify();
                                }
                            }
                        }
                    }))
                    .on_mouse_up(MouseButton::Left, cx.listener(Self::capture_mouse_up))
                    .on_mouse_up_out(MouseButton::Left, cx.listener(Self::capture_mouse_up)),
            )
            .child(
                div()
                    .flex_none()
                    .min_w_0()
                    .border_t_1()
                    .border_color(theme.border)
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(
                        div()
                            .id("browser-capture-marks")
                            .flex()
                            .min_w_0()
                            .h(px(30.))
                            .gap(px(6.))
                            .overflow_x_scroll()
                            .child(
                                control("browser-capture-page-comment", "Page".into())
                                    .when(selected.is_none(), |el| el.border_color(theme.accent))
                                    .when(!busy, |el| {
                                        el.on_click(cx.listener(|this, _, w, cx| {
                                            if let Some(draft) = &mut this.capture {
                                                draft.select(None, w, cx);
                                            }
                                            cx.notify();
                                        }))
                                    }),
                            )
                            .children(draft.marks.iter().enumerate().map(|(index, mark)| {
                                div()
                                    .id(("browser-capture-mark", index))
                                    .flex_none()
                                    .px(px(9.))
                                    .h(px(30.))
                                    .flex()
                                    .items_center()
                                    .rounded(px(5.))
                                    .border_1()
                                    .border_color(if selected == Some(index) {
                                        theme.accent
                                    } else {
                                        theme.border
                                    })
                                    .cursor_pointer()
                                    .role(Role::Button)
                                    .aria_label(format!("Comment for mark {}", index + 1))
                                    .child(format!(
                                        "{}{}",
                                        index + 1,
                                        if mark.comment.trim().is_empty() {
                                            ""
                                        } else {
                                            " ·"
                                        }
                                    ))
                                    .when(!busy, |el| {
                                        el.on_click(cx.listener(move |this, _, w, cx| {
                                            if let Some(draft) = &mut this.capture {
                                                draft.select(Some(index), w, cx);
                                            }
                                            cx.notify();
                                        }))
                                    })
                            })),
                    )
                    .child(
                        div()
                            .flex()
                            .gap(px(8.))
                            .items_center()
                            .min_w_0()
                            .child(div().flex_none().child(label))
                            .when_some(element_label, |el, label| {
                                el.child(
                                    div()
                                        .min_w_0()
                                        .truncate()
                                        .text_color(theme.text_muted)
                                        .child(label),
                                )
                            }),
                    )
                    .child(
                        div()
                            .id("browser-capture-comment")
                            .h(px(76.))
                            .min_h(px(76.))
                            .flex_none()
                            .p(px(8.))
                            .border_1()
                            .border_color(theme.border)
                            .rounded(px(6.))
                            .bg(theme.surface_raised)
                            .overflow_hidden()
                            .cursor_text()
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|this, _, w, cx| {
                                    if let Some(draft) = &mut this.capture {
                                        draft.picking_next = false;
                                        w.focus(&draft.input.focus_handle(cx), cx);
                                        cx.notify();
                                    }
                                }),
                            )
                            .child(input),
                    )
                    .when_some(draft.error.clone(), |el, error| {
                        el.child(
                            div()
                                .text_color(theme.danger)
                                .text_size(crate::typography::ui_rems(11.))
                                .child(error),
                        )
                    })
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap(px(8.))
                            .items_center()
                            .when(selected.is_some(), |el| {
                                el.child(
                                    control("browser-capture-remove", "Remove mark".into()).when(
                                        !busy,
                                        |el| {
                                            el.on_click(cx.listener(|this, _, w, cx| {
                                                if let Some(draft) = &mut this.capture {
                                                    draft.save_comment(cx);
                                                    if let Some(index) = draft.selected.take() {
                                                        draft.marks.remove(index);
                                                    }
                                                    draft.picking_next = false;
                                                    let text = draft.general_comment.clone();
                                                    draft.input.update(cx, |input, cx| {
                                                        input.set_text(text, cx)
                                                    });
                                                    w.focus(&draft.input.focus_handle(cx), cx);
                                                }
                                                cx.notify();
                                            }))
                                        },
                                    ),
                                )
                            })
                            .child(div().flex_1())
                            .when(selected.is_some(), |el| {
                                el.child(
                                    control("browser-capture-next", "Select another".into())
                                        .border_color(theme.accent)
                                        .when(!busy, |el| {
                                            el.on_click(cx.listener(|this, _, window, cx| {
                                                if let Some(draft) = &mut this.capture {
                                                    draft.save_comment(cx);
                                                    draft.picking_next = true;
                                                    draft.start = None;
                                                    draft.selection = None;
                                                    draft.hovered = None;
                                                }
                                                window.focus(&this.focus, cx);
                                                cx.notify();
                                            }))
                                        }),
                                )
                            })
                            .child(
                                control("browser-capture-attach", attach_label)
                                    .bg(theme.accent)
                                    .text_color(theme.bg)
                                    .when(!busy, |el| {
                                        el.on_click(
                                            cx.listener(|this, _, _, cx| this.attach_capture(cx)),
                                        )
                                    }),
                            ),
                    ),
            )
            .into_any_element()
    }
}
