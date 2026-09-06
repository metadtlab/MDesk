//! Controller-side clipboard routing. Local delivery and peer forwarding are
//! separate decisions; every streamed response retains its original requester.
use crate::{file_stream as stream, ClipboardFile};
use std::collections::{HashMap, VecDeque};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Destination {
    Local,
    Peer(String),
}
type Pending = (Destination, ClipboardFile);
pub type Forward = (String, ClipboardFile);
#[derive(Default)]
pub struct FileRoute {
    owner: Option<String>,
    generations: HashMap<u64, String>,
    next_id: u64,
    requests: HashMap<(String, u64), (Destination, u64, u64)>,
    reverse: HashMap<(Destination, u64, u64), (String, u64)>,
    metadata: HashMap<String, VecDeque<Pending>>,
    legacy: HashMap<(String, i32), (Destination, i32)>,
}

impl FileRoute {
    fn id(&mut self) -> u64 {
        self.next_id = self.next_id.wrapping_add(1).max(1);
        self.next_id
    }
    fn request(&mut self, owner: &str, dest: Destination, f: &mut stream::Frame) -> bool {
        if self.requests.len() >= 1024 {
            return false;
        }
        let original = f.request_id;
        let id = self.id();
        self.requests.insert(
            (owner.to_owned(), id),
            (dest.clone(), original, f.generation),
        );
        self.reverse
            .insert((dest, f.generation, original), (owner.to_owned(), id));
        f.request_id = id;
        true
    }
    fn control(&mut self, dest: Destination, f: &mut stream::Frame) -> Option<String> {
        let key = (dest, f.generation, f.request_id);
        let (owner, id) = self.reverse.get(&key)?.clone();
        f.request_id = id;
        if f.kind == stream::CANCEL {
            self.reverse.remove(&key);
            self.requests.remove(&(owner.clone(), id));
        }
        Some(owner)
    }
    fn enqueue_metadata(
        &mut self,
        owner: &str,
        dest: Destination,
        msg: ClipboardFile,
    ) -> Option<ClipboardFile> {
        let queue = self.metadata.entry(owner.to_owned()).or_default();
        if queue.len() >= 32 {
            return None;
        }
        queue.push_back((dest, msg.clone()));
        (queue.len() == 1).then_some(msg)
    }
    /// Every local request uses the same peer queue as forwarded requests.
    pub fn outgoing(&mut self, peer: &str, mut msg: ClipboardFile) -> Option<ClipboardFile> {
        match &mut msg {
            ClipboardFile::FormatList { .. } => self.owner = None,
            ClipboardFile::FileStream(f) => match f.kind {
                stream::REQUEST | stream::DESCRIPTORS_REQUEST => {
                    if !self.request(peer, Destination::Local, f) {
                        return None;
                    }
                }
                stream::CREDIT | stream::CANCEL => {
                    self.control(Destination::Local, f)?;
                }
                _ => {}
            },
            ClipboardFile::FormatDataRequest { .. } => {
                return self.enqueue_metadata(peer, Destination::Local, msg)
            }
            ClipboardFile::FileContentsRequest { stream_id, .. } => {
                if self.legacy.len() >= 1024 {
                    return None;
                }
                let id = self.id() as i32;
                self.legacy
                    .insert((peer.to_owned(), id), (Destination::Local, *stream_id));
                *stream_id = id;
            }
            _ => {}
        }
        Some(msg)
    }
    /// true consumes the message; false allows the (possibly restored) message
    /// to reach the local native clipboard. Outputs must be queued in order.
    pub fn incoming(
        &mut self,
        source: &str,
        msg: &mut ClipboardFile,
        targets: &[String],
    ) -> (bool, Vec<Forward>) {
        let mut forwards = vec![];
        match msg {
            ClipboardFile::FormatList { format_list } => {
                let generation = stream::generation(format_list);
                if generation != 0 {
                    if self
                        .generations
                        .get(&generation)
                        .map_or(false, |p| p != source)
                    {
                        return (true, forwards);
                    }
                    if self.generations.len() >= 64 {
                        self.generations.clear();
                    }
                    self.generations.insert(generation, source.to_owned());
                }
                self.owner = Some(source.to_owned());
                for target in targets.iter().filter(|p| p.as_str() != source) {
                    forwards.push((target.clone(), msg.clone()));
                }
                // Forwarding an advertisement does not install the local IDataObject.
                return (false, forwards);
            }
            ClipboardFile::TryEmpty => {
                if self.owner.as_deref() == Some(source) {
                    self.owner = None;
                    for target in targets.iter().filter(|p| p.as_str() != source) {
                        forwards.push((target.clone(), msg.clone()));
                    }
                }
                return (false, forwards);
            }
            ClipboardFile::FileStream(f) => match f.kind {
                stream::REQUEST | stream::DESCRIPTORS_REQUEST => {
                    if let Some(owner) = self
                        .generations
                        .get(&f.generation)
                        .filter(|p| p.as_str() != source)
                        .cloned()
                    {
                        if self.request(&owner, Destination::Peer(source.to_owned()), f) {
                            forwards.push((owner, msg.clone()));
                        } else {
                            f.kind = stream::ERROR;
                            forwards.push((source.to_owned(), msg.clone()));
                        }
                        return (true, forwards);
                    }
                }
                stream::CREDIT | stream::CANCEL => {
                    if let Some(owner) = self.control(Destination::Peer(source.to_owned()), f) {
                        forwards.push((owner, msg.clone()));
                        return (true, forwards);
                    }
                }
                stream::BLOCK | stream::END | stream::ERROR | stream::DESCRIPTORS_RESPONSE => {
                    let key = (source.to_owned(), f.request_id);
                    if let Some((dest, original, generation)) = self.requests.get(&key).cloned() {
                        if generation != f.generation {
                            return (true, forwards);
                        }
                        if f.kind != stream::BLOCK {
                            self.requests.remove(&key);
                            self.reverse.remove(&(dest.clone(), generation, original));
                        }
                        f.request_id = original;
                        if let Destination::Peer(peer) = dest {
                            forwards.push((peer, msg.clone()));
                            return (true, forwards);
                        }
                    }
                }
                _ => {}
            },
            ClipboardFile::FormatDataRequest { .. } => {
                if let Some(owner) = self.owner.clone().filter(|p| p != source) {
                    if let Some(msg) = self.enqueue_metadata(
                        &owner,
                        Destination::Peer(source.to_owned()),
                        msg.clone(),
                    ) {
                        forwards.push((owner, msg));
                    }
                    return (true, forwards);
                }
            }
            ClipboardFile::FormatDataResponse { .. } => {
                let queue = self.metadata.entry(source.to_owned()).or_default();
                if let Some((dest, _)) = queue.pop_front() {
                    if let Some((_, next)) = queue.front() {
                        forwards.push((source.to_owned(), next.clone()));
                    }
                    if let Destination::Peer(peer) = dest {
                        forwards.push((peer, msg.clone()));
                        return (true, forwards);
                    }
                }
            }
            ClipboardFile::FileContentsRequest { stream_id, .. } => {
                if let Some(owner) = self.owner.clone().filter(|p| p != source) {
                    if self.legacy.len() >= 1024 {
                        return (true, forwards);
                    }
                    let id = self.id() as i32;
                    self.legacy.insert(
                        (owner.clone(), id),
                        (Destination::Peer(source.to_owned()), *stream_id),
                    );
                    *stream_id = id;
                    forwards.push((owner, msg.clone()));
                    return (true, forwards);
                }
            }
            ClipboardFile::FileContentsResponse { stream_id, .. } => {
                if let Some((dest, original)) = self.legacy.remove(&(source.to_owned(), *stream_id))
                {
                    *stream_id = original;
                    if let Destination::Peer(peer) = dest {
                        forwards.push((peer, msg.clone()));
                        return (true, forwards);
                    }
                }
            }
            _ => {}
        }
        (false, forwards)
    }
    pub fn disconnect(&mut self, peer: &str) {
        if self.owner.as_deref() == Some(peer) {
            self.owner = None;
        }
        self.generations.retain(|_, p| p != peer);
        self.requests
            .retain(|(p, _), (d, _, _)| p != peer && *d != Destination::Peer(peer.to_owned()));
        self.reverse
            .retain(|(d, _, _), (p, _)| p != peer && *d != Destination::Peer(peer.to_owned()));
        self.legacy
            .retain(|(p, _), (d, _)| p != peer && *d != Destination::Peer(peer.to_owned()));
        self.metadata.remove(peer);
        for queue in self.metadata.values_mut() {
            // Keep the in-flight head until its untagged legacy reply arrives.
            // Removing it early could complete the next request with that reply.
            let head = queue.pop_front();
            queue.retain(|(dest, _)| *dest != Destination::Peer(peer.to_owned()));
            if let Some(head) = head {
                queue.push_front(head);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn formats(generation: u64) -> ClipboardFile {
        ClipboardFile::FormatList {
            format_list: vec![(0, format!("{}{:016x}", stream::FORMAT_PREFIX, generation))],
        }
    }
    fn request(id: u64) -> ClipboardFile {
        ClipboardFile::FileStream(stream::Frame {
            kind: stream::REQUEST,
            generation: 7,
            request_id: id,
            ..Default::default()
        })
    }
    #[test]
    fn relaying_preserves_local_install_and_new_copies() {
        let mut r = FileRoute::default();
        assert!(!r.incoming("A", &mut formats(7), &["B".into()]).0);
        assert!(!r.incoming("B", &mut formats(8), &["A".into()]).0);
        assert_eq!(r.owner.as_deref(), Some("B"));
        assert!(r.incoming("C", &mut formats(7), &[]).0);
    }
    #[test]
    fn simultaneous_equal_ids_restore_correct_requester() {
        let mut r = FileRoute::default();
        r.incoming("A", &mut formats(7), &[]);
        let (_, b) = r.incoming("B", &mut request(1), &[]);
        let (_, c) = r.incoming("C", &mut request(1), &[]);
        for (out, target) in [(b, "B"), (c, "C")] {
            let mut msg = out[0].1.clone();
            let ClipboardFile::FileStream(f) = &mut msg else {
                panic!()
            };
            f.kind = stream::BLOCK;
            let (handled, output) = r.incoming("A", &mut msg, &[]);
            assert!(handled);
            assert_eq!(output[0].0, target);
            let ClipboardFile::FileStream(f) = &output[0].1 else {
                panic!()
            };
            assert_eq!(f.request_id, 1);
        }
    }
    #[test]
    fn unrelated_empty_keeps_route_and_local_reply_is_restored() {
        let mut r = FileRoute::default();
        r.incoming("A", &mut formats(7), &[]);
        let mut sent = r.outgoing("A", request(987)).unwrap();
        r.incoming("C", &mut ClipboardFile::TryEmpty, &[]);
        assert_eq!(r.owner.as_deref(), Some("A"));
        let ClipboardFile::FileStream(f) = &mut sent else {
            panic!()
        };
        f.kind = stream::END;
        assert!(!r.incoming("A", &mut sent, &[]).0);
        let ClipboardFile::FileStream(f) = sent else {
            panic!()
        };
        assert_eq!(f.request_id, 987);
    }
    #[test]
    fn cancel_cleans_mapping_without_disturbing_other_requesters() {
        let mut r = FileRoute::default();
        r.incoming("A", &mut formats(7), &[]);
        r.incoming("B", &mut request(10), &[]);
        r.incoming("C", &mut request(10), &[]);
        let mut cancel = request(10);
        let ClipboardFile::FileStream(f) = &mut cancel else {
            panic!()
        };
        f.kind = stream::CANCEL;
        let (handled, output) = r.incoming("B", &mut cancel, &[]);
        assert!(handled);
        assert_eq!(output[0].0, "A");
        assert_eq!(r.requests.len(), 1);
        assert_eq!(r.reverse.len(), 1);
        assert!(r
            .reverse
            .contains_key(&(Destination::Peer("C".into()), 7, 10)));
        r.disconnect("C");
        assert!(r.requests.is_empty() && r.reverse.is_empty());
    }
    #[test]
    fn legacy_metadata_is_serialized_and_disconnect_keeps_inflight_reply_correlated() {
        let mut r = FileRoute::default();
        r.incoming("A", &mut formats(7), &[]);
        let req = ClipboardFile::FormatDataRequest {
            requested_format_id: 123,
        };
        assert_eq!(r.incoming("B", &mut req.clone(), &[]).1.len(), 1);
        assert!(r.incoming("B", &mut req.clone(), &[]).1.is_empty());
        assert!(r.outgoing("A", req).is_none());
        r.disconnect("B");
        assert_eq!(r.metadata["A"].len(), 2);
        let mut reply = ClipboardFile::FormatDataResponse {
            msg_flags: 1,
            format_data: vec![1],
        };
        let (handled, output) = r.incoming("A", &mut reply, &[]);
        assert!(handled);
        assert_eq!(output.len(), 2); // next local request + old reply to B
        assert!(!r.incoming("A", &mut reply, &[]).0);
    }
}
