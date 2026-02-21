use monty::MontyObject;
use num_bigint::BigInt;
use num_traits::ToPrimitive;
use serde_json::{Number, Value, json};

/// Convert a `MontyObject` to a JSON `Value`.
///
/// Key mappings:
/// - `None` → `null`
/// - `Bool` → `true`/`false`
/// - `Int` → number
/// - `BigInt` → number if fits i64, else string
/// - `Float` → number
/// - `String` → string
/// - `List`/`Tuple` → array
/// - `Dict` → object (string keys) or array of `[k, v]` pairs
/// - `Ellipsis` → `"..."`
/// - `Bytes` → array of ints
/// - `Set`/`FrozenSet` → array
pub fn monty_object_to_json(obj: &MontyObject) -> Value {
    match obj {
        MontyObject::None => Value::Null,
        MontyObject::Bool(b) => Value::Bool(*b),
        MontyObject::Int(n) => json!(n),
        MontyObject::BigInt(n) => bigint_to_json(n),
        MontyObject::Float(f) => float_to_json(*f),
        MontyObject::String(s) => Value::String(s.clone()),
        MontyObject::List(items) | MontyObject::Tuple(items) => {
            Value::Array(items.iter().map(monty_object_to_json).collect())
        }
        MontyObject::Dict(pairs) => dict_to_json(pairs),
        MontyObject::Set(items) | MontyObject::FrozenSet(items) => {
            Value::Array(items.iter().map(monty_object_to_json).collect())
        }
        MontyObject::Ellipsis => Value::String("...".into()),
        MontyObject::Bytes(bytes) => Value::Array(bytes.iter().map(|b| json!(*b)).collect()),
        MontyObject::NamedTuple { values, .. } => {
            Value::Array(values.iter().map(monty_object_to_json).collect())
        }
        MontyObject::Path(p) => Value::String(p.clone()),
        MontyObject::Dataclass { attrs, .. } => dict_to_json(attrs),
        MontyObject::Type(t) => Value::String(format!("{t}")),
        MontyObject::BuiltinFunction(f) => Value::String(format!("{f:?}")),
        MontyObject::Exception { exc_type, arg } => {
            let msg = match arg {
                Some(a) => format!("{exc_type}: {a}"),
                None => format!("{exc_type}"),
            };
            Value::String(msg)
        }
        MontyObject::Repr(r) => Value::String(r.clone()),
        MontyObject::Cycle(_, desc) => Value::String(desc.clone()),
    }
}

/// Convert a JSON `Value` back to a `MontyObject` (for resume values).
pub fn json_to_monty_object(val: &Value) -> MontyObject {
    match val {
        Value::Null => MontyObject::None,
        Value::Bool(b) => MontyObject::Bool(*b),
        Value::Number(n) => number_to_monty_object(n),
        Value::String(s) => MontyObject::String(s.clone()),
        Value::Array(items) => MontyObject::List(items.iter().map(json_to_monty_object).collect()),
        Value::Object(map) => {
            let pairs: Vec<(MontyObject, MontyObject)> = map
                .iter()
                .map(|(k, v)| (MontyObject::String(k.clone()), json_to_monty_object(v)))
                .collect();
            MontyObject::dict(pairs)
        }
    }
}

fn bigint_to_json(n: &BigInt) -> Value {
    if let Some(i) = n.to_i64() {
        json!(i)
    } else {
        Value::String(n.to_string())
    }
}

fn float_to_json(f: f64) -> Value {
    if f.is_finite() {
        Number::from_f64(f)
            .map(Value::Number)
            .unwrap_or(Value::Null)
    } else if f.is_nan() {
        Value::String("NaN".into())
    } else if f.is_sign_positive() {
        Value::String("Infinity".into())
    } else {
        Value::String("-Infinity".into())
    }
}

fn number_to_monty_object(n: &Number) -> MontyObject {
    if let Some(i) = n.as_i64() {
        MontyObject::Int(i)
    } else if let Some(f) = n.as_f64() {
        MontyObject::Float(f)
    } else {
        // u64 that doesn't fit i64
        MontyObject::BigInt(BigInt::from(n.as_u64().unwrap_or(0)))
    }
}

fn dict_to_json(pairs: &monty::DictPairs) -> Value {
    // Collect pairs via the &DictPairs IntoIterator impl.
    let items: Vec<&(MontyObject, MontyObject)> = pairs.into_iter().collect();
    let all_string_keys = items
        .iter()
        .all(|(k, _)| matches!(k, MontyObject::String(_)));

    if all_string_keys {
        let map: serde_json::Map<String, Value> = items
            .into_iter()
            .map(|(k, v)| {
                let key = match k {
                    MontyObject::String(s) => s.clone(),
                    _ => unreachable!(),
                };
                (key, monty_object_to_json(v))
            })
            .collect();
        Value::Object(map)
    } else {
        Value::Array(
            items
                .into_iter()
                .map(|(k, v)| json!([monty_object_to_json(k), monty_object_to_json(v)]))
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_none() {
        assert_eq!(monty_object_to_json(&MontyObject::None), Value::Null);
    }

    #[test]
    fn test_bool() {
        assert_eq!(monty_object_to_json(&MontyObject::Bool(true)), json!(true));
        assert_eq!(
            monty_object_to_json(&MontyObject::Bool(false)),
            json!(false)
        );
    }

    #[test]
    fn test_int() {
        assert_eq!(monty_object_to_json(&MontyObject::Int(42)), json!(42));
        assert_eq!(monty_object_to_json(&MontyObject::Int(-1)), json!(-1));
        assert_eq!(monty_object_to_json(&MontyObject::Int(0)), json!(0));
    }

    #[test]
    fn test_bigint_fits_i64() {
        let n = BigInt::from(123_456_789i64);
        assert_eq!(
            monty_object_to_json(&MontyObject::BigInt(n)),
            json!(123_456_789)
        );
    }

    #[test]
    fn test_bigint_too_large() {
        let n = BigInt::parse_bytes(b"99999999999999999999999", 10).unwrap();
        let val = monty_object_to_json(&MontyObject::BigInt(n.clone()));
        assert_eq!(val, Value::String(n.to_string()));
    }

    #[test]
    fn test_float() {
        assert_eq!(monty_object_to_json(&MontyObject::Float(3.14)), json!(3.14));
    }

    #[test]
    fn test_float_nan() {
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(f64::NAN)),
            Value::String("NaN".into())
        );
    }

    #[test]
    fn test_float_infinity() {
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(f64::INFINITY)),
            Value::String("Infinity".into())
        );
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(f64::NEG_INFINITY)),
            Value::String("-Infinity".into())
        );
    }

    #[test]
    fn test_string() {
        assert_eq!(
            monty_object_to_json(&MontyObject::String("hello".into())),
            json!("hello")
        );
    }

    #[test]
    fn test_list() {
        let list = MontyObject::List(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        assert_eq!(monty_object_to_json(&list), json!([1, 2]));
    }

    #[test]
    fn test_tuple() {
        let tuple = MontyObject::Tuple(vec![MontyObject::Bool(true), MontyObject::None]);
        assert_eq!(monty_object_to_json(&tuple), json!([true, null]));
    }

    #[test]
    fn test_dict_string_keys() {
        let pairs = vec![
            (MontyObject::String("a".into()), MontyObject::Int(1)),
            (MontyObject::String("b".into()), MontyObject::Int(2)),
        ];
        let dict = MontyObject::dict(pairs);
        let val = monty_object_to_json(&dict);
        assert_eq!(val["a"], json!(1));
        assert_eq!(val["b"], json!(2));
    }

    #[test]
    fn test_dict_non_string_keys() {
        let pairs = vec![
            (MontyObject::Int(1), MontyObject::String("a".into())),
            (MontyObject::Int(2), MontyObject::String("b".into())),
        ];
        let dict = MontyObject::dict(pairs);
        let val = monty_object_to_json(&dict);
        assert_eq!(val, json!([[1, "a"], [2, "b"]]));
    }

    #[test]
    fn test_set() {
        let set = MontyObject::Set(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        assert_eq!(monty_object_to_json(&set), json!([1, 2]));
    }

    #[test]
    fn test_ellipsis() {
        assert_eq!(monty_object_to_json(&MontyObject::Ellipsis), json!("..."));
    }

    #[test]
    fn test_bytes() {
        let bytes = MontyObject::Bytes(vec![72, 105]);
        assert_eq!(monty_object_to_json(&bytes), json!([72, 105]));
    }

    // Round-trip tests
    #[test]
    fn test_round_trip_null() {
        let original = MontyObject::None;
        let json = monty_object_to_json(&original);
        let back = json_to_monty_object(&json);
        assert!(matches!(back, MontyObject::None));
    }

    #[test]
    fn test_round_trip_bool() {
        let json = monty_object_to_json(&MontyObject::Bool(true));
        let back = json_to_monty_object(&json);
        assert!(matches!(back, MontyObject::Bool(true)));
    }

    #[test]
    fn test_round_trip_int() {
        let json = monty_object_to_json(&MontyObject::Int(42));
        let back = json_to_monty_object(&json);
        assert!(matches!(back, MontyObject::Int(42)));
    }

    #[test]
    fn test_round_trip_string() {
        let json = monty_object_to_json(&MontyObject::String("hello".into()));
        let back = json_to_monty_object(&json);
        assert!(matches!(back, MontyObject::String(ref s) if s == "hello"));
    }

    #[test]
    fn test_round_trip_list() {
        let list = MontyObject::List(vec![MontyObject::Int(1), MontyObject::None]);
        let json = monty_object_to_json(&list);
        let back = json_to_monty_object(&json);
        match back {
            MontyObject::List(items) => {
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(items[1], MontyObject::None));
            }
            _ => panic!("expected list"),
        }
    }

    #[test]
    fn test_json_to_monty_object_object() {
        let val = json!({"key": "value"});
        let obj = json_to_monty_object(&val);
        match obj {
            MontyObject::Dict(pairs) => {
                let items: Vec<_> = pairs.into_iter().collect::<Vec<_>>();
                assert_eq!(items.len(), 1);
            }
            _ => panic!("expected dict"),
        }
    }
}
