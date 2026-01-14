use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::filter_schema::FilterSchema;

/// Registry for all available filter schemas.
///
/// Loads built-in filters from the schemas directory and user filters from
/// the user's config directory.
pub struct FilterRegistry {
    filters: HashMap<String, FilterSchema>,
    load_order: Vec<String>,
}

impl FilterRegistry {
    /// Create a new empty registry.
    pub fn new() -> Self {
        Self {
            filters: HashMap::new(),
            load_order: Vec::new(),
        }
    }

    /// Load all available filters.
    pub fn load_all(&mut self, schemas_dir: &Path) -> Result<()> {
        // Load built-in filters
        self.load_from_directory(schemas_dir, "builtin")?;

        // Load user filters
        if let Some(user_dir) = Self::get_user_filter_directory() {
            if user_dir.exists() {
                self.load_from_directory(&user_dir, "user")?;
            }
        }

        Ok(())
    }

    /// Load filters from a directory.
    pub fn load_from_directory(&mut self, dir: &Path, source: &str) -> Result<()> {
        if !dir.exists() {
            return Ok(());
        }

        // Load from core/ subdirectory if it exists
        let core_dir = dir.join("core");
        let search_dir = if core_dir.exists() { &core_dir } else { dir };

        for entry in fs::read_dir(search_dir)? {
            let entry = entry?;
            let path = entry.path();

            if path.extension().map(|e| e == "json").unwrap_or(false) {
                if let Err(e) = self.load_from_file(&path, source) {
                    eprintln!("Warning: Failed to load filter schema from {:?}: {}", path, e);
                }
            }
        }

        Ok(())
    }

    /// Load a single filter from a file.
    pub fn load_from_file(&mut self, path: &Path, source: &str) -> Result<FilterSchema> {
        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read filter schema: {:?}", path))?;

        let mut schema: FilterSchema = serde_json::from_str(&content)
            .with_context(|| format!("Failed to parse filter schema: {:?}", path))?;

        schema.source = source.to_string();
        self.register(schema.clone());

        Ok(schema)
    }

    /// Register a filter schema.
    pub fn register(&mut self, schema: FilterSchema) {
        // Remove from load order if already exists (for overrides)
        self.load_order.retain(|id| id != &schema.id);

        self.filters.insert(schema.id.clone(), schema);
        self.load_order.push(self.filters.keys().last().unwrap().clone());
    }

    /// Get all registered filters in load order.
    pub fn filters(&self) -> impl Iterator<Item = &FilterSchema> {
        self.load_order.iter().filter_map(|id| self.filters.get(id))
    }

    /// Get all filters sorted by their order property.
    pub fn ordered_filters(&self) -> Vec<&FilterSchema> {
        let mut filters: Vec<_> = self.filters.values().collect();
        filters.sort_by_key(|f| f.order);
        filters
    }

    /// Get a filter by ID.
    pub fn get(&self, id: &str) -> Option<&FilterSchema> {
        self.filters.get(id)
    }

    /// Check if a filter exists.
    pub fn has(&self, id: &str) -> bool {
        self.filters.contains_key(id)
    }

    /// Get the user filter directory path.
    fn get_user_filter_directory() -> Option<PathBuf> {
        #[cfg(windows)]
        {
            std::env::var("USERPROFILE")
                .ok()
                .map(|home| PathBuf::from(home).join(".vapourbox").join("filters"))
        }

        #[cfg(not(windows))]
        {
            std::env::var("HOME")
                .ok()
                .map(|home| PathBuf::from(home).join(".vapourbox").join("filters"))
        }
    }

    /// Validate that all required dependencies are available.
    pub fn validate_dependencies(&self, plugin_dir: &Path) -> HashMap<String, Vec<String>> {
        let mut missing = HashMap::new();

        for filter in self.filters.values() {
            if let Some(deps) = &filter.dependencies {
                let mut filter_missing = Vec::new();

                // Check VS plugins
                if let Some(vs_plugins) = &deps.vs_plugins {
                    for plugin in vs_plugins {
                        let plugin_path = plugin_dir.join(plugin);
                        if !plugin_path.exists() {
                            filter_missing.push(plugin.clone());
                        }
                    }
                }

                if !filter_missing.is_empty() {
                    missing.insert(filter.id.clone(), filter_missing);
                }
            }
        }

        missing
    }
}

impl Default for FilterRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_load_from_json() {
        let mut registry = FilterRegistry::new();

        let json = r#"{
            "id": "test_filter",
            "version": "1.0.0",
            "name": "Test Filter",
            "methods": [
                {
                    "id": "method1",
                    "name": "Method 1",
                    "function": "test.func",
                    "parameters": []
                }
            ],
            "parameters": {}
        }"#;

        let schema: FilterSchema = serde_json::from_str(json).unwrap();
        registry.register(schema);

        assert!(registry.has("test_filter"));
        assert_eq!(registry.get("test_filter").unwrap().name, "Test Filter");
    }

    #[test]
    fn test_load_from_directory() {
        let dir = tempdir().unwrap();
        let core_dir = dir.path().join("core");
        fs::create_dir(&core_dir).unwrap();

        let schema_json = r#"{
            "id": "file_filter",
            "version": "1.0.0",
            "name": "File Filter",
            "methods": [],
            "parameters": {}
        }"#;

        fs::write(core_dir.join("test.json"), schema_json).unwrap();

        let mut registry = FilterRegistry::new();
        registry.load_from_directory(dir.path(), "test").unwrap();

        assert!(registry.has("file_filter"));
    }
}
