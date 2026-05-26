//! Build-time codegen from `tools/openapi.yaml`: auth route list and DTOs.

use std::path::Path;
use std::{env, fs};

use serde_yaml::Value;

const SPEC_PATH: &str = "../../tools/openapi.yaml";
const HTTP_METHODS: &[&str] = &["get", "post", "put", "delete", "patch"];

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={SPEC_PATH}");

    let raw = fs::read_to_string(SPEC_PATH)
        .unwrap_or_else(|e| panic!("failed to read {SPEC_PATH}: {e}"));
    // The spec uses literal tab characters in a few places; the YAML parser
    // rejects tabs as indentation. Normalize to spaces before parsing.
    let normalized = raw.replace('\t', "    ");

    let spec_value: Value = serde_yaml::from_str(&normalized)
        .unwrap_or_else(|e| panic!("failed to parse {SPEC_PATH}: {e}"));
    emit_auth_routes(&spec_value);

    let mut spec: openapiv3::OpenAPI = serde_yaml::from_str(&normalized)
        .unwrap_or_else(|e| panic!("failed to deserialize {SPEC_PATH} into openapiv3::OpenAPI: {e}"));
    // progenitor's token generation rejects unsupported operation shapes
    // (e.g. our spec's multipart/form-data bodies); clearing paths lets
    // emission succeed. The dropped operations and Client would be discarded
    // anyway by the `ast.items.retain` step in `emit_dtos`.
    spec.paths.paths.clear();
    emit_dtos(&spec);
}

/// Emit `AUTH_REQUIRED_ROUTES` and `ANONYMOUS_ROUTES`: routes partitioned by
/// whether their `security` field references `api_key`.
fn emit_auth_routes(spec: &Value) {
    let global_security = spec.get("security");

    let paths = spec
        .get("paths")
        .and_then(Value::as_mapping)
        .expect("openapi.yaml: missing `paths` mapping");

    let mut auth_required: Vec<(String, String)> = Vec::new();
    let mut anonymous: Vec<(String, String)> = Vec::new();

    for (path_key, path_item) in paths {
        let path = path_key
            .as_str()
            .expect("openapi.yaml: path key is not a string");
        let item = path_item
            .as_mapping()
            .expect("openapi.yaml: path item is not a mapping");

        for method in HTTP_METHODS {
            let Some(op) = item.get(Value::String((*method).to_string())) else {
                continue;
            };
            let upper = method.to_uppercase();
            if operation_requires_api_key(op, global_security) {
                auth_required.push((upper, path.to_string()));
            } else {
                anonymous.push((upper, path.to_string()));
            }
        }
    }

    auth_required.sort();
    anonymous.sort();

    let mut out = String::new();
    out.push_str("/// Routes that openapi.yaml marks with `security: api_key`.\n");
    out.push_str("#[allow(dead_code)]\n");
    out.push_str("pub const AUTH_REQUIRED_ROUTES: &[(&str, &str)] = &[\n");
    for (method, path) in &auth_required {
        out.push_str(&format!("    ({method:?}, {path:?}),\n"));
    }
    out.push_str("];\n\n");
    out.push_str("/// Routes that openapi.yaml does not mark with `security`.\n");
    out.push_str("#[allow(dead_code)]\n");
    out.push_str("pub const ANONYMOUS_ROUTES: &[(&str, &str)] = &[\n");
    for (method, path) in &anonymous {
        out.push_str(&format!("    ({method:?}, {path:?}),\n"));
    }
    out.push_str("];\n");

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR not set by cargo");
    let dest = Path::new(&out_dir).join("auth_routes.rs");
    fs::write(&dest, out).unwrap_or_else(|e| {
        panic!("failed to write {}: {e}", dest.display())
    });
}

/// `true` when the operation (or the global fallback) declares the `api_key`
/// security scheme. Operation-level `security: []` explicitly disables auth
/// for this op, overriding any global.
fn operation_requires_api_key(op: &Value, global_security: Option<&Value>) -> bool {
    let security = op.get("security").or(global_security);
    let Some(security) = security else {
        return false;
    };
    let Some(seq) = security.as_sequence() else {
        return false;
    };
    seq.iter().any(|req| {
        req.as_mapping()
            .is_some_and(|m| m.contains_key(Value::String("api_key".into())))
    })
}

/// Emit Rust structs/enums for every `components.schemas` entry via progenitor.
/// Only the `pub mod types { ... }` submodule is retained; the generated
/// `Client` and its impls are dropped so we don't pull `progenitor-client` /
/// `reqwest` into the runtime dep graph.
fn emit_dtos(spec: &openapiv3::OpenAPI) {
    let mut generator = progenitor::Generator::default();
    let tokens = generator
        .generate_tokens(spec)
        .expect("progenitor failed to generate tokens from openapi.yaml");
    let mut ast: syn::File = syn::parse2(tokens)
        .expect("progenitor emitted a token stream that does not parse as a syn::File");
    ast.items.retain(|item| {
        matches!(item, syn::Item::Mod(m) if m.ident == "types")
    });
    let formatted = prettyplease::unparse(&ast);

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR not set by cargo");
    let dest = Path::new(&out_dir).join("openapi_types.rs");
    fs::write(&dest, formatted).unwrap_or_else(|e| {
        panic!("failed to write {}: {e}", dest.display())
    });
}
