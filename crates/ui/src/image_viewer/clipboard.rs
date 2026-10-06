use gpui::{App, Image, Task};
use std::sync::Arc;

#[cfg(target_os = "linux")]
#[derive(Default)]
struct ImageClipboard(Arc<std::sync::Mutex<Option<arboard::Clipboard>>>);

#[cfg(target_os = "linux")]
impl gpui::Global for ImageClipboard {}

pub(super) fn copy(image: Arc<Image>, cx: &mut App) -> Task<Result<(), String>> {
    #[cfg(target_os = "linux")]
    {
        let clipboard = cx.default_global::<ImageClipboard>().0.clone();
        cx.background_executor().spawn(async move {
            let raster = image
                .to_image_data(gpui::SvgRenderer::new(Arc::new(crate::icons::Assets)))
                .map_err(|error| error.to_string())?;
            let dimensions = raster.size(0);
            let mut rgba = raster
                .as_bytes(0)
                .ok_or("Image has no pixel data")?
                .to_vec();
            for pixel in rgba.chunks_exact_mut(4) {
                pixel.swap(0, 2);
            }
            let mut clipboard = clipboard.lock().map_err(|error| error.to_string())?;
            if clipboard.is_none() {
                *clipboard = Some(arboard::Clipboard::new().map_err(|error| error.to_string())?);
            }
            clipboard
                .as_mut()
                .ok_or("Clipboard unavailable")?
                .set_image(arboard::ImageData {
                    width: dimensions.width.0 as usize,
                    height: dimensions.height.0 as usize,
                    bytes: rgba.into(),
                })
                .map_err(|error| error.to_string())
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        cx.write_to_clipboard(gpui::ClipboardItem::new_image(&image));
        Task::ready(Ok(()))
    }
}
