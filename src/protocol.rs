use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub id: Uuid,
    pub function: String,
    pub args: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub id: Uuid,
    pub success: bool,
    pub result: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Request {
    pub fn new(function: String, args: Value) -> Self {
        Self {
            id: Uuid::new_v4(),
            function,
            args,
            timeout_ms: None,
        }
    }

    pub fn with_timeout(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = Some(timeout_ms);
        self
    }
}

impl Response {
    pub fn success(id: Uuid, result: Value) -> Self {
        Self {
            id,
            success: true,
            result,
            error: None,
        }
    }

    pub fn error(id: Uuid, error: String) -> Self {
        Self {
            id,
            success: false,
            result: Value::Null,
            error: Some(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_request_serialization() {
        let request = Request::new(
            "test_function".to_string(),
            serde_json::json!({"key": "value"}),
        );

        let serialized = serde_json::to_string(&request).unwrap();
        let deserialized: Request = serde_json::from_str(&serialized).unwrap();

        assert_eq!(request.function, deserialized.function);
        assert_eq!(request.args, deserialized.args);
    }

    #[test]
    fn test_response_serialization() {
        let id = Uuid::new_v4();
        let response = Response::success(id, serde_json::json!({"result": 42}));

        let serialized = serde_json::to_string(&response).unwrap();
        let deserialized: Response = serde_json::from_str(&serialized).unwrap();

        assert_eq!(response.id, deserialized.id);
        assert_eq!(response.success, deserialized.success);
        assert_eq!(response.result, deserialized.result);
    }
}