use super::{DocsStore, StoreError};
use rusqlite::{OptionalExtension, params};
use zeron_doc::{MessagePart, MessageRole, SessionDoc, join_continuation_entries};
use zeron_proto::{MessageSearchHit, MessageSearchResults};

fn searchable_messages(bytes: &[u8]) -> Result<Vec<(String, String)>, String> {
    let doc = loro::LoroDoc::new();
    doc.import(bytes).map_err(|error| error.to_string())?;
    let entries = SessionDoc::from_doc(doc)
        .read_entries()
        .map_err(|error| error.to_string())?;
    Ok(join_continuation_entries(entries)
        .into_iter()
        .filter_map(|entry| {
            if !matches!(entry.role, MessageRole::User | MessageRole::Assistant) {
                return None;
            }
            let text = entry
                .parts
                .into_iter()
                .filter_map(|part| match part {
                    MessagePart::Text { text, .. } => Some(text),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n");
            (!text.trim().is_empty()).then_some((entry.id, text))
        })
        .collect())
}

impl DocsStore {
    pub fn search_messages(
        &self,
        chat_ids: &[String],
        query: &str,
        limit: usize,
    ) -> Result<MessageSearchResults, StoreError> {
        let terms = query
            .chars()
            .take(256)
            .collect::<String>()
            .split(|c: char| !c.is_alphanumeric() && c != '_')
            .filter(|word| !word.is_empty())
            .take(32)
            .map(|word| format!("\"{}\"*", word.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" AND ");
        if terms.is_empty() {
            return Ok(MessageSearchResults::default());
        }
        for chat in chat_ids {
            let pending: Option<(i64, Vec<u8>)> = self.conn().query_row(
                "SELECT state.revision,snapshots.bytes FROM message_search_state state
                 JOIN snapshots USING(doc_id) WHERE doc_id=?1 AND state.revision!=state.indexed_revision",
                [chat], |row| Ok((row.get(0)?,row.get(1)?)),
            ).optional()?;
            let Some((revision, bytes)) = pending else {
                continue;
            };
            let messages = searchable_messages(&bytes);
            drop(bytes);
            let mut conn = self.conn();
            let tx = conn.transaction()?;
            let current = tx.query_row(
                "SELECT state.revision FROM message_search_state state JOIN snapshots USING(doc_id) WHERE doc_id=?1",
                [chat], |row| row.get::<_, i64>(0),
            ).optional()?;
            if current != Some(revision) {
                continue;
            }
            tx.execute("DELETE FROM message_search_rows WHERE chat_id=?1", [chat])?;
            let readable = messages.is_ok();
            if let Ok(messages) = messages {
                let mut insert = tx.prepare_cached(
                    "INSERT INTO message_search_rows(chat_id,message_id,body) VALUES(?1,?2,?3)",
                )?;
                for (message, body) in messages {
                    insert.execute(params![chat, message, body])?;
                }
            }
            tx.execute(
                "UPDATE message_search_state SET indexed_revision=?2,readable=?3 WHERE doc_id=?1",
                params![chat, revision, readable],
            )?;
            tx.commit()?;
        }
        let allowed = serde_json::to_string(chat_ids).unwrap_or_else(|_| "[]".into());
        let conn = self.conn();
        let indexed_chats: usize = conn.query_row(
            "SELECT COUNT(*) FROM message_search_state state JOIN snapshots USING(doc_id)
             WHERE state.readable=1 AND state.indexed_revision=state.revision
             AND doc_id IN (SELECT value FROM json_each(?1))",
            [&allowed],
            |row| row.get(0),
        )?;
        let mut statement = conn.prepare_cached(
            "SELECT messages.chat_id,messages.message_id,snippet(message_search_fts,0,'','',' … ',36)
             FROM message_search_fts JOIN message_search_rows messages ON messages.id=message_search_fts.rowid
             JOIN message_search_state state ON state.doc_id=messages.chat_id
             WHERE message_search_fts MATCH ?1 AND state.readable=1 AND state.indexed_revision=state.revision
             AND messages.chat_id IN (SELECT value FROM json_each(?2))
             ORDER BY rank LIMIT ?3",
        )?;
        let hits = statement
            .query_map(params![terms, allowed, limit.clamp(1, 50)], |row| {
                Ok(MessageSearchHit {
                    chat_id: row.get(0)?,
                    message_id: row.get(1)?,
                    snippet: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(MessageSearchResults {
            hits,
            indexed_chats,
            unavailable_chats: chat_ids.len().saturating_sub(indexed_chats),
        })
    }
}
