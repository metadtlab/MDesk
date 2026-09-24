use image::{codecs::jpeg::JpegDecoder, DynamicImage, ImageDecoder};
use nokhwa::{pixel_format::RgbAFormat, utils::FrameFormat, Buffer};
use std::io::{self, Cursor};

// Nokhwa's native MJPEG decoder unwinds on malformed input. With panic=abort
// this kills the host process, including unrelated remote desktop sessions.
// USB cameras can deliver a partial JPEG immediately after opening the stream.
pub(super) fn decode_rgba(buffer: &Buffer) -> io::Result<(Vec<u8>, usize, usize)> {
    let resolution = buffer.resolution();
    let width = resolution.width();
    let height = resolution.height();
    let data = if buffer.source_frame_format() == FrameFormat::MJPEG {
        let decoder = JpegDecoder::new(Cursor::new(buffer.buffer())).map_err(invalid_frame)?;
        if decoder.dimensions() != (width, height) {
            return Err(invalid_frame(
                "JPEG dimensions differ from camera resolution",
            ));
        }
        DynamicImage::from_decoder(decoder)
            .map_err(invalid_frame)?
            .into_rgba8()
            .into_raw()
    } else {
        buffer
            .decode_image::<RgbAFormat>()
            .map_err(invalid_frame)?
            .into_raw()
    };
    Ok((data, width as usize, height as usize))
}

fn invalid_frame(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{codecs::jpeg::JpegEncoder, ColorType};
    use nokhwa::utils::Resolution;

    fn jpeg_frame() -> Vec<u8> {
        let mut jpeg = Vec::new();
        let pixels = [240, 20, 10].repeat(8 * 8);
        JpegEncoder::new_with_quality(&mut jpeg, 90)
            .encode(&pixels, 8, 8, ColorType::Rgb8)
            .unwrap();
        jpeg
    }

    fn frame(data: &[u8]) -> Buffer {
        Buffer::new(Resolution::new(8, 8), data, FrameFormat::MJPEG)
    }

    #[test]
    fn partial_startup_frame_does_not_prevent_next_frame() {
        let jpeg = jpeg_frame();
        assert_eq!(
            decode_rgba(&frame(&jpeg[20..])).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        let (rgba, width, height) = decode_rgba(&frame(&jpeg)).unwrap();
        assert_eq!((width, height, rgba.len()), (8, 8, 8 * 8 * 4));
        assert!(rgba
            .chunks_exact(4)
            .all(|p| p[0] > 220 && p[1] < 40 && p[2] < 30 && p[3] == 255));
    }

    #[test]
    fn malformed_jpeg_with_soi_returns_error() {
        // Checking only the JPEG magic would still pass this broken header to
        // the native decoder and abort the process.
        for data in [
            &[][..],
            &[0xff, 0xd8][..],
            &[0xff, 0xd8, 0xff, 0xc0, 0, 1][..],
        ] {
            assert_eq!(
                decode_rgba(&frame(data)).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
    }

    #[test]
    fn mismatched_dimensions_are_rejected() {
        let frame = Buffer::new(Resolution::new(16, 8), &jpeg_frame(), FrameFormat::MJPEG);
        assert_eq!(
            decode_rgba(&frame).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn raw_rgb_keeps_channel_order() {
        let frame = Buffer::new(
            Resolution::new(2, 1),
            &[1, 2, 3, 4, 5, 6],
            FrameFormat::RAWRGB,
        );
        assert_eq!(
            decode_rgba(&frame).unwrap(),
            (vec![1, 2, 3, 255, 4, 5, 6, 255], 2, 1)
        );
    }
}
