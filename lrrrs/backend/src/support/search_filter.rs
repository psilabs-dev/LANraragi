//! Search query tokenizer.
//!
//! Parses the LRR search filter string into a list of [`SearchToken`]s.
//! The token grammar supports:
//! - Comma-separated terms (AND logic; all must match)
//! - `"..."` for exact/quoted terms (whitespace included in token, wildcards still active)
//! - `-` prefix for negation
//! - `$` suffix for exact match (no substring widening)
//! - `?` / `_` single-character wildcards, `*` / `%` multi-character wildcards

/// A single parsed search term.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchToken {
    /// The lowercased tag string, including namespace prefix if present.
    pub tag: String,
    /// When true, archives matching this token should be *excluded*.
    pub isneg: bool,
    /// When true, value is matched exactly (no substring widening).
    pub isexact: bool,
}

/// Parse an LRR search filter string into tokens.
///
/// Blank tokens are discarded. Tokens are lowercased.
pub fn compute_search_filter(filter: &str) -> Vec<SearchToken> {
    let mut tokens = Vec::new();

    // Work over a char-indexed sequence.
    let chars: Vec<char> = filter.chars().collect();
    let mut i = 0;
    let len = chars.len();

    while i < len {
        // Skip spaces between tokens
        while i < len && chars[i] == ' ' {
            i += 1;
        }
        if i >= len {
            break;
        }

        // Check for negation prefix
        let isneg = if chars[i] == '-' {
            i += 1;
            true
        } else {
            false
        };

        if i >= len {
            break;
        }

        // Determine delimiter: '"' starts a quoted term, ',' ends an unquoted term
        let (delimiter, quoted) = if chars[i] == '"' {
            i += 1; // consume the opening quote
            ('"', true)
        } else {
            (',', false)
        };

        // Collect characters until delimiter or end
        let mut tag = String::new();
        while i < len && chars[i] != delimiter {
            // For unquoted terms, also stop at comma-space boundaries
            tag.push(chars[i]);
            i += 1;
        }

        // Determine isexact
        let isexact = if quoted {
            // Consume closing quote
            if i < len && chars[i] == '"' {
                i += 1;
            }
            // Optional trailing $ after closing quote (valid syntax, does nothing extra)
            if i < len && chars[i] == '$' {
                i += 1;
            }
            true
        } else {
            // Check if last char of tag is '$'
            if tag.ends_with('$') {
                tag.pop();
                true
            } else {
                false
            }
        };

        // Skip the comma delimiter for unquoted terms
        if !quoted && i < len && chars[i] == ',' {
            i += 1;
        }

        // Trim whitespace (mirrors Perl's `trim`)
        let tag = tag.trim().to_string();
        let tag = tag.to_lowercase();

        if !tag.is_empty() {
            tokens.push(SearchToken { tag, isneg, isexact });
        }
    }

    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tok(tag: &str, isneg: bool, isexact: bool) -> SearchToken {
        SearchToken { tag: tag.to_string(), isneg, isexact }
    }

    #[test]
    fn empty_filter_returns_no_tokens() {
        assert_eq!(compute_search_filter(""), vec![]);
    }

    #[test]
    fn single_plain_token() {
        assert_eq!(
            compute_search_filter("ghost"),
            vec![tok("ghost", false, false)]
        );
    }

    #[test]
    fn two_comma_separated_tokens() {
        assert_eq!(
            compute_search_filter("artist:wada rco, character:ereshkigal"),
            vec![
                tok("artist:wada rco", false, false),
                tok("character:ereshkigal", false, false),
            ]
        );
    }

    #[test]
    fn negation_prefix() {
        let tokens = compute_search_filter("artist:wada rco, -character:ereshkigal");
        assert_eq!(tokens[1], tok("character:ereshkigal", true, false));
    }

    #[test]
    fn dollar_suffix_sets_isexact() {
        let tokens = compute_search_filter("character:segata$");
        assert_eq!(tokens, vec![tok("character:segata", false, true)]);
    }

    #[test]
    fn quoted_term_sets_isexact() {
        let tokens = compute_search_filter("\"Fate GO MEMO\"");
        assert_eq!(tokens, vec![tok("fate go memo", false, true)]);
    }

    #[test]
    fn quoted_term_with_wildcards() {
        let tokens = compute_search_filter("\"Fate GO MEMO ?\"");
        assert_eq!(tokens, vec![tok("fate go memo ?", false, true)]);
    }

    #[test]
    fn quoted_then_dollar_is_exact() {
        // "foo"$: closing $ after quote is accepted and token is still exact
        let tokens = compute_search_filter("\"Saturn Backup Cartridge - *\"$");
        assert_eq!(tokens, vec![tok("saturn backup cartridge - *", false, true)]);
    }

    #[test]
    fn negation_inside_quotes_is_literal() {
        // "-character:waver velvet": hyphen inside quotes is literal, not negation
        let tokens = compute_search_filter("\"artist:wada rco\" \"-character:waver velvet\"");
        assert_eq!(
            tokens,
            vec![
                tok("artist:wada rco", false, true),
                tok("-character:waver velvet", false, true),
            ]
        );
    }

    #[test]
    fn blank_tokens_discarded() {
        let tokens = compute_search_filter(",  ,");
        assert_eq!(tokens, vec![]);
    }

    #[test]
    fn tokens_are_lowercased() {
        let tokens = compute_search_filter("Ghost");
        assert_eq!(tokens[0].tag, "ghost");
    }

    #[test]
    fn wildcard_asterisk_survives() {
        let tokens = compute_search_filter("*male:very cool");
        assert_eq!(tokens, vec![tok("*male:very cool", false, false)]);
    }

    #[test]
    fn pages_range_token() {
        let tokens = compute_search_filter("pages:>150");
        assert_eq!(tokens, vec![tok("pages:>150", false, false)]);
    }

    #[test]
    fn multiple_range_tokens() {
        let tokens = compute_search_filter("read:<10, read:>4");
        assert_eq!(
            tokens,
            vec![tok("read:<10", false, false), tok("read:>4", false, false)]
        );
    }
}
