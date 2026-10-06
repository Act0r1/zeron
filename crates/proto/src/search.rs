use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSearchHit {
    pub chat_id: String,
    pub message_id: String,
    pub snippet: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSearchResults {
    pub hits: Vec<MessageSearchHit>,
    pub indexed_chats: usize,
    pub unavailable_chats: usize,
}
