//! Schema-based VapourSynth script generator.
//!
//! Generates VapourSynth filter calls from filter schemas and dynamic parameters.

use std::collections::HashMap;

use crate::filter_schema::{FilterSchema, DynamicParameters, ParameterType};

/// Generates VapourSynth code from filter schemas.
pub struct SchemaScriptGenerator;

impl SchemaScriptGenerator {
    /// Generate a VapourSynth filter call from a schema and parameters.
    ///
    /// Returns a string like:
    /// `clip = haf.DeHalo_alpha(clip, rx=2.0, ry=2.0, darkstr=1.0)`
    pub fn generate_filter_call(
        schema: &FilterSchema,
        params: &DynamicParameters,
    ) -> Option<String> {
        if !params.enabled {
            return None;
        }

        // Get the selected method
        let method_id = params.method().unwrap_or_else(|| {
            schema.methods.first().map(|m| m.id.as_str()).unwrap_or("")
        });

        let method = schema.get_method(method_id)
            .or_else(|| schema.methods.first())?;

        // Build arguments
        let mut args = Vec::new();

        for param_name in &method.parameters {
            if let Some(param_def) = schema.parameters.get(param_name) {
                if let Some(value) = params.values.get(param_name) {
                    let vs_name = param_def.get_vs_name(param_name);
                    let formatted = format_value(value, &param_def.param_type);
                    args.push(format!("{}={}", vs_name, formatted));
                }
            }
        }

        let args_str = args.join(", ");

        if args_str.is_empty() {
            Some(format!("clip = {}(clip)", method.function))
        } else {
            Some(format!("clip = {}(clip, {})", method.function, args_str))
        }
    }

    /// Generate import statements for a filter.
    pub fn generate_imports(schema: &FilterSchema) -> Vec<String> {
        schema.code_template
            .as_ref()
            .and_then(|ct| ct.imports.clone())
            .unwrap_or_default()
    }

    /// Generate code block for a filter including any method-specific logic.
    ///
    /// This handles more complex cases where the code template has custom body.
    pub fn generate_filter_block(
        schema: &FilterSchema,
        params: &DynamicParameters,
    ) -> Option<String> {
        if !params.enabled {
            return None;
        }

        // Check if there's a custom code template
        if let Some(ct) = &schema.code_template {
            if let Some(body) = &ct.body {
                // Substitute parameters into custom template
                return Some(substitute_template(body, &params.values, schema));
            }
        }

        // Otherwise use standard method-based generation
        Self::generate_filter_call(schema, params)
    }

    /// Validate that required dependencies are documented.
    pub fn get_required_imports(schemas: &[&FilterSchema]) -> Vec<String> {
        let mut imports = Vec::new();

        for schema in schemas {
            for import in Self::generate_imports(schema) {
                if !imports.contains(&import) {
                    imports.push(import);
                }
            }
        }

        imports
    }
}

/// Format a JSON value for VapourSynth Python code.
fn format_value(value: &serde_json::Value, param_type: &ParameterType) -> String {
    match (value, param_type) {
        (serde_json::Value::Bool(b), _) => {
            if *b { "True" } else { "False" }.to_string()
        }
        (serde_json::Value::Number(n), ParameterType::Integer) => {
            n.as_i64().map(|v| v.to_string()).unwrap_or_else(|| "0".to_string())
        }
        (serde_json::Value::Number(n), ParameterType::Number) => {
            n.as_f64().map(|v| {
                // Format with appropriate precision, removing trailing zeros
                let formatted = format!("{:.4}", v);
                let trimmed = formatted.trim_end_matches('0').trim_end_matches('.');
                if trimmed.contains('.') {
                    trimmed.to_string()
                } else {
                    format!("{}.0", trimmed)
                }
            }).unwrap_or_else(|| "0.0".to_string())
        }
        (serde_json::Value::Number(n), _) => {
            // Generic number handling
            if let Some(i) = n.as_i64() {
                i.to_string()
            } else if let Some(f) = n.as_f64() {
                format!("{}", f)
            } else {
                "0".to_string()
            }
        }
        (serde_json::Value::String(s), _) => {
            format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
        }
        (serde_json::Value::Null, _) => "None".to_string(),
        (serde_json::Value::Array(arr), _) => {
            let items: Vec<String> = arr.iter()
                .map(|v| format_value(v, &ParameterType::String))
                .collect();
            format!("[{}]", items.join(", "))
        }
        _ => "None".to_string(),
    }
}

/// Substitute parameters into a custom code template.
fn substitute_template(
    template: &str,
    values: &HashMap<String, serde_json::Value>,
    schema: &FilterSchema,
) -> String {
    let mut result = template.to_string();

    for (param_name, value) in values {
        let param_type = schema.parameters.get(param_name)
            .map(|p| &p.param_type)
            .unwrap_or(&ParameterType::String);

        let formatted = format_value(value, param_type);

        // Replace {{param_name}} and {{PARAM_NAME}} variations
        result = result.replace(&format!("{{{{{}}}}}", param_name), &formatted);
        result = result.replace(&format!("{{{{{}}}}}", param_name.to_uppercase()), &formatted);
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_schema() -> FilterSchema {
        let json = r#"{
            "id": "dehalo",
            "version": "1.0.0",
            "name": "Dehalo",
            "methods": [
                {
                    "id": "dehalo_alpha",
                    "name": "DeHalo Alpha",
                    "function": "haf.DeHalo_alpha",
                    "parameters": ["rx", "ry", "darkStr"]
                },
                {
                    "id": "yahr",
                    "name": "YAHR",
                    "function": "haf.YAHR",
                    "parameters": ["blur", "depth"]
                }
            ],
            "parameters": {
                "method": {
                    "type": "enum",
                    "default": "dehalo_alpha",
                    "options": ["dehalo_alpha", "yahr"]
                },
                "rx": {
                    "type": "number",
                    "default": 2.0,
                    "vapoursynth": { "name": "rx" }
                },
                "ry": {
                    "type": "number",
                    "default": 2.0,
                    "vapoursynth": { "name": "ry" }
                },
                "darkStr": {
                    "type": "number",
                    "default": 1.0,
                    "vapoursynth": { "name": "darkstr" }
                },
                "blur": {
                    "type": "integer",
                    "default": 2
                },
                "depth": {
                    "type": "integer",
                    "default": 32
                }
            },
            "codeTemplate": {
                "imports": ["import havsfunc as haf"]
            }
        }"#;

        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn test_generate_filter_call() {
        let schema = create_test_schema();

        let mut values = HashMap::new();
        values.insert("method".to_string(), serde_json::json!("dehalo_alpha"));
        values.insert("rx".to_string(), serde_json::json!(2.0));
        values.insert("ry".to_string(), serde_json::json!(2.0));
        values.insert("darkStr".to_string(), serde_json::json!(1.0));

        let params = DynamicParameters {
            filter_id: "dehalo".to_string(),
            enabled: true,
            values,
        };

        let result = SchemaScriptGenerator::generate_filter_call(&schema, &params);
        assert!(result.is_some());

        let code = result.unwrap();
        assert!(code.contains("haf.DeHalo_alpha"));
        assert!(code.contains("rx=2.0"));
        assert!(code.contains("ry=2.0"));
        assert!(code.contains("darkstr=1.0"));
    }

    #[test]
    fn test_generate_yahr_method() {
        let schema = create_test_schema();

        let mut values = HashMap::new();
        values.insert("method".to_string(), serde_json::json!("yahr"));
        values.insert("blur".to_string(), serde_json::json!(2));
        values.insert("depth".to_string(), serde_json::json!(32));

        let params = DynamicParameters {
            filter_id: "dehalo".to_string(),
            enabled: true,
            values,
        };

        let result = SchemaScriptGenerator::generate_filter_call(&schema, &params);
        assert!(result.is_some());

        let code = result.unwrap();
        assert!(code.contains("haf.YAHR"));
        assert!(code.contains("blur=2"));
        assert!(code.contains("depth=32"));
    }

    #[test]
    fn test_disabled_filter() {
        let schema = create_test_schema();

        let params = DynamicParameters {
            filter_id: "dehalo".to_string(),
            enabled: false,
            values: HashMap::new(),
        };

        let result = SchemaScriptGenerator::generate_filter_call(&schema, &params);
        assert!(result.is_none());
    }

    #[test]
    fn test_format_values() {
        assert_eq!(format_value(&serde_json::json!(true), &ParameterType::Boolean), "True");
        assert_eq!(format_value(&serde_json::json!(false), &ParameterType::Boolean), "False");
        assert_eq!(format_value(&serde_json::json!(42), &ParameterType::Integer), "42");
        assert_eq!(format_value(&serde_json::json!(3.14159), &ParameterType::Number), "3.1416");
        assert_eq!(format_value(&serde_json::json!("test"), &ParameterType::String), "\"test\"");
    }
}
