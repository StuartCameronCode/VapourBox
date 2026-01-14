use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Type of parameter value.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ParameterType {
    Boolean,
    Integer,
    Number,
    String,
    #[serde(rename = "enum")]
    Enum,
}

/// Type of UI widget to render for a parameter.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum WidgetType {
    Slider,
    Dropdown,
    Checkbox,
    Textfield,
    Number,
}

/// VapourSynth-specific parameter configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VapourSynthConfig {
    /// The parameter name in VapourSynth (may differ from schema name).
    pub name: String,
}

/// UI configuration for a parameter.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ParameterUiConfig {
    /// Display label for the parameter.
    pub label: Option<String>,

    /// Description/tooltip for the parameter.
    pub description: Option<String>,

    /// Type of widget to render.
    pub widget: Option<WidgetType>,

    /// Decimal precision for number display.
    pub precision: Option<i32>,

    /// Whether this parameter is hidden from the UI.
    pub hidden: Option<bool>,

    /// Condition for when this parameter is visible.
    #[serde(rename = "visibleWhen")]
    pub visible_when: Option<HashMap<String, serde_json::Value>>,
}

/// Definition of a single parameter.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParameterDefinition {
    /// Type of this parameter.
    #[serde(rename = "type")]
    pub param_type: ParameterType,

    /// Default value (type depends on param_type).
    #[serde(rename = "default")]
    pub default_value: serde_json::Value,

    /// Minimum value (for number/integer types).
    pub min: Option<f64>,

    /// Maximum value (for number/integer types).
    pub max: Option<f64>,

    /// Step size for sliders.
    pub step: Option<f64>,

    /// Available options (for enum type).
    pub options: Option<Vec<String>>,

    /// VapourSynth-specific configuration.
    pub vapoursynth: Option<VapourSynthConfig>,

    /// UI configuration.
    pub ui: Option<ParameterUiConfig>,
}

impl ParameterDefinition {
    /// Get the VapourSynth parameter name.
    pub fn get_vs_name<'a>(&'a self, schema_name: &'a str) -> &'a str {
        self.vapoursynth
            .as_ref()
            .map(|vs| vs.name.as_str())
            .unwrap_or(schema_name)
    }

    /// Check if a value is valid for this parameter.
    pub fn is_valid_value(&self, value: &serde_json::Value) -> bool {
        match (&self.param_type, value) {
            (ParameterType::Boolean, serde_json::Value::Bool(_)) => true,
            (ParameterType::Integer, serde_json::Value::Number(n)) => {
                if !n.is_i64() {
                    return false;
                }
                let v = n.as_i64().unwrap();
                if let Some(min) = self.min {
                    if (v as f64) < min {
                        return false;
                    }
                }
                if let Some(max) = self.max {
                    if (v as f64) > max {
                        return false;
                    }
                }
                true
            }
            (ParameterType::Number, serde_json::Value::Number(n)) => {
                if let Some(v) = n.as_f64() {
                    if let Some(min) = self.min {
                        if v < min {
                            return false;
                        }
                    }
                    if let Some(max) = self.max {
                        if v > max {
                            return false;
                        }
                    }
                    true
                } else {
                    false
                }
            }
            (ParameterType::String, serde_json::Value::String(_)) => true,
            (ParameterType::Enum, serde_json::Value::String(s)) => {
                self.options.as_ref().map(|opts| opts.contains(s)).unwrap_or(true)
            }
            (_, serde_json::Value::Null) => true,
            _ => false,
        }
    }
}

/// Definition of a filter method (e.g., DeHalo_alpha, YAHR).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MethodDefinition {
    /// Unique identifier for this method.
    pub id: String,

    /// Display name.
    pub name: String,

    /// Description of what this method does.
    pub description: Option<String>,

    /// VapourSynth function to call (e.g., "haf.DeHalo_alpha").
    pub function: String,

    /// List of parameter IDs that this method uses.
    pub parameters: Vec<String>,
}

/// UI section grouping parameters together.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiSection {
    /// Section title.
    pub title: String,

    /// Parameter IDs in this section.
    pub parameters: Vec<String>,

    /// Whether the section is expanded by default.
    #[serde(default = "default_true")]
    pub expanded: bool,

    /// Whether this section only appears in advanced mode.
    #[serde(default)]
    pub advanced_only: bool,
}

fn default_true() -> bool {
    true
}

/// UI layout configuration.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UiLayout {
    /// Sections to organize parameters.
    pub sections: Option<Vec<UiSection>>,
}

/// Dependencies required by a filter.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FilterDependencies {
    /// Python packages required (e.g., ["havsfunc", "mvsfunc"]).
    pub plugins: Option<Vec<String>>,

    /// VapourSynth plugins required (e.g., ["libmvtools.dll"]).
    #[serde(rename = "vs_plugins")]
    pub vs_plugins: Option<Vec<String>>,

    /// Optional plugins that enable additional features.
    pub optional: Option<Vec<String>>,
}

/// Code generation configuration.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CodeTemplate {
    /// Import statements needed.
    pub imports: Option<Vec<String>>,

    /// How to generate code: "method" (use method.function) or custom template.
    pub generate: Option<String>,

    /// Custom code body template.
    pub body: Option<String>,
}

/// Complete filter schema definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilterSchema {
    /// JSON Schema reference (optional).
    #[serde(rename = "$schema")]
    pub schema: Option<String>,

    /// Unique identifier for this filter.
    pub id: String,

    /// Schema version.
    pub version: String,

    /// Display name.
    pub name: String,

    /// Description of what this filter does.
    pub description: Option<String>,

    /// Category for grouping.
    pub category: Option<String>,

    /// Icon name.
    pub icon: Option<String>,

    /// Sort order in filter list.
    #[serde(default)]
    pub order: i32,

    /// Dependencies required by this filter.
    pub dependencies: Option<FilterDependencies>,

    /// Available methods for this filter.
    pub methods: Vec<MethodDefinition>,

    /// Parameter definitions.
    pub parameters: HashMap<String, ParameterDefinition>,

    /// Preset configurations.
    pub presets: Option<HashMap<String, HashMap<String, serde_json::Value>>>,

    /// UI layout configuration.
    pub ui: Option<UiLayout>,

    /// Code generation configuration.
    #[serde(rename = "codeTemplate")]
    pub code_template: Option<CodeTemplate>,

    /// Source of this schema (not serialized).
    #[serde(skip)]
    pub source: String,
}

impl FilterSchema {
    /// Get the default method.
    pub fn default_method(&self) -> Option<&MethodDefinition> {
        self.methods.first()
    }

    /// Get a method by ID.
    pub fn get_method(&self, id: &str) -> Option<&MethodDefinition> {
        self.methods.iter().find(|m| m.id == id)
    }

    /// Get default values for all parameters.
    pub fn get_defaults(&self) -> HashMap<String, serde_json::Value> {
        self.parameters
            .iter()
            .map(|(k, v)| (k.clone(), v.default_value.clone()))
            .collect()
    }

    /// Validate parameter values against schema.
    pub fn validate(&self, values: &HashMap<String, serde_json::Value>) -> Vec<String> {
        let mut errors = Vec::new();

        for (key, value) in values {
            match self.parameters.get(key) {
                Some(param) => {
                    if !param.is_valid_value(value) {
                        errors.push(format!("Invalid value for {}: {:?}", key, value));
                    }
                }
                None => {
                    errors.push(format!("Unknown parameter: {}", key));
                }
            }
        }

        errors
    }
}

/// Dynamic parameter container for schema-based filters.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DynamicParameters {
    /// The filter ID this belongs to.
    pub filter_id: String,

    /// Whether this filter pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Parameter values.
    #[serde(default)]
    pub values: HashMap<String, serde_json::Value>,
}

impl DynamicParameters {
    /// Create with default values from a schema.
    pub fn from_schema(schema: &FilterSchema, enabled: bool) -> Self {
        Self {
            filter_id: schema.id.clone(),
            enabled,
            values: schema.get_defaults(),
        }
    }

    /// Get a boolean parameter.
    pub fn get_bool(&self, key: &str) -> Option<bool> {
        self.values.get(key).and_then(|v| v.as_bool())
    }

    /// Get an integer parameter.
    pub fn get_int(&self, key: &str) -> Option<i64> {
        self.values.get(key).and_then(|v| v.as_i64())
    }

    /// Get a float parameter.
    pub fn get_float(&self, key: &str) -> Option<f64> {
        self.values.get(key).and_then(|v| v.as_f64())
    }

    /// Get a string parameter.
    pub fn get_string(&self, key: &str) -> Option<&str> {
        self.values.get(key).and_then(|v| v.as_str())
    }

    /// Get the currently selected method ID.
    pub fn method(&self) -> Option<&str> {
        self.get_string("method")
    }
}

/// Container for all dynamic filter parameters in a pipeline.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DynamicPipeline {
    /// Map of filter ID to parameters.
    #[serde(default)]
    pub filters: HashMap<String, DynamicParameters>,
}

impl DynamicPipeline {
    /// Get parameters for a specific filter.
    pub fn get(&self, filter_id: &str) -> Option<&DynamicParameters> {
        self.filters.get(filter_id)
    }

    /// Check if a filter is enabled.
    pub fn is_enabled(&self, filter_id: &str) -> bool {
        self.filters.get(filter_id).map(|p| p.enabled).unwrap_or(false)
    }

    /// Get list of enabled filter IDs.
    pub fn enabled_filter_ids(&self) -> Vec<&str> {
        self.filters
            .iter()
            .filter(|(_, p)| p.enabled)
            .map(|(id, _)| id.as_str())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_filter_schema() {
        let json = r#"{
            "id": "dehalo",
            "version": "1.0.0",
            "name": "Dehalo",
            "order": 4,
            "methods": [
                {
                    "id": "dehalo_alpha",
                    "name": "DeHalo Alpha",
                    "function": "haf.DeHalo_alpha",
                    "parameters": ["rx", "ry"]
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
                    "min": 1.0,
                    "max": 3.0
                }
            }
        }"#;

        let schema: FilterSchema = serde_json::from_str(json).unwrap();
        assert_eq!(schema.id, "dehalo");
        assert_eq!(schema.methods.len(), 1);
        assert_eq!(schema.parameters.len(), 2);
    }

    #[test]
    fn test_parameter_validation() {
        let param = ParameterDefinition {
            param_type: ParameterType::Number,
            default_value: serde_json::json!(2.0),
            min: Some(1.0),
            max: Some(3.0),
            step: Some(0.1),
            options: None,
            vapoursynth: None,
            ui: None,
        };

        assert!(param.is_valid_value(&serde_json::json!(2.0)));
        assert!(param.is_valid_value(&serde_json::json!(1.0)));
        assert!(param.is_valid_value(&serde_json::json!(3.0)));
        assert!(!param.is_valid_value(&serde_json::json!(0.5)));
        assert!(!param.is_valid_value(&serde_json::json!(3.5)));
    }
}
