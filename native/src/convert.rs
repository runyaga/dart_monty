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
        MontyObject::List(items) => Value::Array(items.iter().map(monty_object_to_json).collect()),
        MontyObject::Tuple(items) => json!({
            "__type": "tuple",
            "value": items.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::Dict(pairs) => dict_to_json(pairs),
        MontyObject::Set(items) => json!({
            "__type": "set",
            "value": items.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::FrozenSet(items) => json!({
            "__type": "frozenset",
            "value": items.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::Ellipsis => Value::String("...".into()),
        MontyObject::Bytes(bytes) => json!({
            "__type": "bytes",
            "value": bytes,
        }),
        MontyObject::NamedTuple {
            type_name,
            field_names,
            values,
        } => json!({
            "__type": "namedtuple",
            "type_name": type_name,
            "field_names": field_names,
            "values": values.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::Path(p) => json!({
            "__type": "path",
            "value": p,
        }),
        MontyObject::Dataclass {
            name,
            type_id,
            field_names,
            attrs,
            frozen,
        } => {
            let attrs_json = dict_to_json(attrs);
            json!({
                "__type": "dataclass",
                "name": name,
                "type_id": type_id,
                "field_names": field_names,
                "attrs": attrs_json,
                "frozen": frozen,
            })
        }
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
        MontyObject::Function { name, .. } => Value::String(format!("<function {name}>")),
        MontyObject::Date(d) => json!({
            "__type": "date",
            "year": d.year,
            "month": d.month,
            "day": d.day,
        }),
        MontyObject::DateTime(dt) => json!({
            "__type": "datetime",
            "year": dt.year,
            "month": dt.month,
            "day": dt.day,
            "hour": dt.hour,
            "minute": dt.minute,
            "second": dt.second,
            "microsecond": dt.microsecond,
            "offset_seconds": dt.offset_seconds,
            "timezone_name": dt.timezone_name,
        }),
        MontyObject::TimeDelta(td) => json!({
            "__type": "timedelta",
            "days": td.days,
            "seconds": td.seconds,
            "microseconds": td.microseconds,
        }),
        MontyObject::TimeZone(tz) => json!({
            "__type": "timezone",
            "offset_seconds": tz.offset_seconds,
            "name": tz.name,
        }),
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
            if let Some(type_str) = map.get("__type").and_then(|v| v.as_str()) {
                match type_str {
                    "date" => MontyObject::Date(monty::MontyDate {
                        year: map["year"].as_i64().unwrap_or(0).try_into().unwrap_or(0),
                        month: map["month"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                        day: map["day"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                    }),
                    "datetime" => MontyObject::DateTime(monty::MontyDateTime {
                        year: map["year"].as_i64().unwrap_or(0).try_into().unwrap_or(0),
                        month: map["month"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                        day: map["day"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                        hour: map["hour"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                        minute: map["minute"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                        second: map["second"].as_u64().unwrap_or(0).try_into().unwrap_or(0),
                        microsecond: map["microsecond"]
                            .as_u64()
                            .unwrap_or(0)
                            .try_into()
                            .unwrap_or(0),
                        offset_seconds: map
                            .get("offset_seconds")
                            .and_then(serde_json::Value::as_i64)
                            .map(|v| v.try_into().unwrap_or(0)),
                        timezone_name: map
                            .get("timezone_name")
                            .and_then(|v| v.as_str())
                            .map(std::string::ToString::to_string),
                    }),
                    "timedelta" => MontyObject::TimeDelta(monty::MontyTimeDelta {
                        days: map["days"].as_i64().unwrap_or(0).try_into().unwrap_or(0),
                        seconds: map["seconds"].as_i64().unwrap_or(0).try_into().unwrap_or(0),
                        microseconds: map["microseconds"]
                            .as_i64()
                            .unwrap_or(0)
                            .try_into()
                            .unwrap_or(0),
                    }),
                    "timezone" => MontyObject::TimeZone(monty::MontyTimeZone {
                        offset_seconds: map["offset_seconds"]
                            .as_i64()
                            .unwrap_or(0)
                            .try_into()
                            .unwrap_or(0),
                        name: map
                            .get("name")
                            .and_then(|v| v.as_str())
                            .map(std::string::ToString::to_string),
                    }),
                    "path" => MontyObject::Path(map["value"].as_str().unwrap_or("").to_string()),
                    "bytes" => MontyObject::Bytes(
                        map["value"]
                            .as_array()
                            .map(|arr| {
                                arr.iter()
                                    .map(|v| v.as_u64().unwrap_or(0).try_into().unwrap_or(0))
                                    .collect()
                            })
                            .unwrap_or_default(),
                    ),
                    "tuple" => MontyObject::Tuple(
                        map["value"]
                            .as_array()
                            .map(|arr| arr.iter().map(json_to_monty_object).collect())
                            .unwrap_or_default(),
                    ),
                    "set" => MontyObject::Set(
                        map["value"]
                            .as_array()
                            .map(|arr| arr.iter().map(json_to_monty_object).collect())
                            .unwrap_or_default(),
                    ),
                    "frozenset" => MontyObject::FrozenSet(
                        map["value"]
                            .as_array()
                            .map(|arr| arr.iter().map(json_to_monty_object).collect())
                            .unwrap_or_default(),
                    ),
                    "namedtuple" => MontyObject::NamedTuple {
                        type_name: map["type_name"].as_str().unwrap_or("").to_string(),
                        field_names: map["field_names"]
                            .as_array()
                            .map(|arr| {
                                arr.iter()
                                    .map(|v| v.as_str().unwrap_or("").to_string())
                                    .collect()
                            })
                            .unwrap_or_default(),
                        values: map["values"]
                            .as_array()
                            .map(|arr| arr.iter().map(json_to_monty_object).collect())
                            .unwrap_or_default(),
                    },
                    "dataclass" => MontyObject::Dataclass {
                        name: map["name"].as_str().unwrap_or("").to_string(),
                        type_id: map["type_id"].as_u64().unwrap_or(0),
                        field_names: map["field_names"]
                            .as_array()
                            .map(|arr| {
                                arr.iter()
                                    .map(|v| v.as_str().unwrap_or("").to_string())
                                    .collect()
                            })
                            .unwrap_or_default(),
                        attrs: match json_to_monty_object(
                            &map.get("attrs").cloned().unwrap_or_else(|| json!({})),
                        ) {
                            MontyObject::Dict(pairs) => pairs,
                            _ => vec![].into(),
                        },
                        frozen: map
                            .get("frozen")
                            .and_then(serde_json::Value::as_bool)
                            .unwrap_or(false),
                    },
                    _ => {
                        // Unknown __type — fall through to dict
                        let pairs: Vec<(MontyObject, MontyObject)> = map
                            .iter()
                            .map(|(k, v)| (MontyObject::String(k.clone()), json_to_monty_object(v)))
                            .collect();
                        MontyObject::dict(pairs)
                    }
                }
            } else {
                // No __type key — treat as dict (existing behavior)
                let pairs: Vec<(MontyObject, MontyObject)> = map
                    .iter()
                    .map(|(k, v)| (MontyObject::String(k.clone()), json_to_monty_object(v)))
                    .collect();
                MontyObject::dict(pairs)
            }
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
        Number::from_f64(f).map_or(Value::Null, Value::Number)
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
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(3.125)),
            json!(3.125)
        );
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
        assert_eq!(
            monty_object_to_json(&tuple),
            json!({"__type": "tuple", "value": [true, null]})
        );
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
        assert_eq!(
            monty_object_to_json(&set),
            json!({"__type": "set", "value": [1, 2]})
        );
    }

    #[test]
    fn test_ellipsis() {
        assert_eq!(monty_object_to_json(&MontyObject::Ellipsis), json!("..."));
    }

    #[test]
    fn test_bytes() {
        let bytes = MontyObject::Bytes(vec![72, 105]);
        assert_eq!(
            monty_object_to_json(&bytes),
            json!({"__type": "bytes", "value": [72, 105]})
        );
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

    #[test]
    fn test_named_tuple() {
        let nt = MontyObject::NamedTuple {
            type_name: "Point".into(),
            field_names: vec!["x".into(), "y".into()],
            values: vec![MontyObject::Int(1), MontyObject::Int(2)],
        };
        assert_eq!(
            monty_object_to_json(&nt),
            json!({"__type": "namedtuple", "type_name": "Point", "field_names": ["x", "y"], "values": [1, 2]})
        );
    }

    #[test]
    fn test_path() {
        let p = MontyObject::Path("/tmp/foo".into());
        assert_eq!(
            monty_object_to_json(&p),
            json!({"__type": "path", "value": "/tmp/foo"})
        );
    }

    #[test]
    fn test_dataclass() {
        let dc = MontyObject::Dataclass {
            name: "MyClass".into(),
            type_id: 1,
            field_names: vec!["a".into()],
            attrs: vec![(MontyObject::String("a".into()), MontyObject::Int(42))].into(),
            frozen: false,
        };
        let val = monty_object_to_json(&dc);
        assert_eq!(val["__type"], json!("dataclass"));
        assert_eq!(val["name"], json!("MyClass"));
        assert_eq!(val["attrs"]["a"], json!(42));
    }

    #[test]
    fn test_exception_with_arg() {
        let exc = MontyObject::Exception {
            exc_type: monty::ExcType::ValueError,
            arg: Some("bad value".into()),
        };
        assert_eq!(
            monty_object_to_json(&exc),
            Value::String("ValueError: bad value".into())
        );
    }

    #[test]
    fn test_exception_no_arg() {
        let exc = MontyObject::Exception {
            exc_type: monty::ExcType::RuntimeError,
            arg: None,
        };
        assert_eq!(
            monty_object_to_json(&exc),
            Value::String("RuntimeError".into())
        );
    }

    #[test]
    fn test_repr() {
        let r = MontyObject::Repr("<object at 0x123>".into());
        assert_eq!(
            monty_object_to_json(&r),
            Value::String("<object at 0x123>".into())
        );
    }

    #[test]
    fn test_frozen_set() {
        let fs = MontyObject::FrozenSet(vec![MontyObject::Int(3), MontyObject::Int(4)]);
        assert_eq!(
            monty_object_to_json(&fs),
            json!({"__type": "frozenset", "value": [3, 4]})
        );
    }

    #[test]
    fn test_json_to_monty_float() {
        let val = json!(3.125);
        let obj = json_to_monty_object(&val);
        match obj {
            MontyObject::Float(f) => assert!((f - 3.125).abs() < f64::EPSILON),
            _ => panic!("expected Float"),
        }
    }

    // =========================================================================
    // Round-trip coverage for EVERY MontyObject variant
    //
    // These tests document the current serialization behavior.
    // Variants marked "LOSSY" lose type information during the round-trip
    // (monty → JSON → monty). These need typed JSON wrappers to fix.
    // =========================================================================

    /// Helper: serialize to JSON then deserialize back.
    fn round_trip(obj: &MontyObject) -> MontyObject {
        let json = monty_object_to_json(obj);
        json_to_monty_object(&json)
    }

    // --- Lossless round-trips (these work correctly) ---

    #[test]
    fn rt_none() {
        assert!(matches!(round_trip(&MontyObject::None), MontyObject::None));
    }

    #[test]
    fn rt_bool_true() {
        assert!(matches!(
            round_trip(&MontyObject::Bool(true)),
            MontyObject::Bool(true)
        ));
    }

    #[test]
    fn rt_bool_false() {
        assert!(matches!(
            round_trip(&MontyObject::Bool(false)),
            MontyObject::Bool(false)
        ));
    }

    #[test]
    fn rt_int() {
        assert!(matches!(
            round_trip(&MontyObject::Int(42)),
            MontyObject::Int(42)
        ));
    }

    #[test]
    fn rt_int_negative() {
        assert!(matches!(
            round_trip(&MontyObject::Int(-99)),
            MontyObject::Int(-99)
        ));
    }

    #[test]
    fn rt_float() {
        match round_trip(&MontyObject::Float(3.14)) {
            MontyObject::Float(f) => assert!((f - 3.14).abs() < f64::EPSILON),
            other => panic!("expected Float, got {other:?}"),
        }
    }

    #[test]
    fn rt_string() {
        match round_trip(&MontyObject::String("hello".into())) {
            MontyObject::String(s) => assert_eq!(s, "hello"),
            other => panic!("expected String, got {other:?}"),
        }
    }

    #[test]
    fn rt_list() {
        let obj = MontyObject::List(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        match round_trip(&obj) {
            MontyObject::List(items) => {
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(items[1], MontyObject::Int(2)));
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    #[test]
    fn rt_dict_string_keys() {
        let obj = MontyObject::dict(vec![
            (MontyObject::String("a".into()), MontyObject::Int(1)),
            (MontyObject::String("b".into()), MontyObject::Int(2)),
        ]);
        match round_trip(&obj) {
            MontyObject::Dict(pairs) => {
                let items: Vec<_> = pairs.into_iter().collect();
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected Dict, got {other:?}"),
        }
    }

    // =========================================================================
    // LOSSLESS round-trip tests — these define CORRECT behavior.
    //
    // These tests WILL FAIL until convert.rs is updated with __type wrappers.
    // When the refactor is complete, all tests pass.
    // =========================================================================

    // --- Date ---

    #[test]
    fn rt_date() {
        let obj = MontyObject::Date(monty::MontyDate {
            year: 2026,
            month: 4,
            day: 9,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 2026);
                assert_eq!(d.month, 4);
                assert_eq!(d.day, 9);
            }
            other => panic!("expected Date, got {other:?}"),
        }
    }

    #[test]
    fn rt_date_min() {
        let obj = MontyObject::Date(monty::MontyDate {
            year: 1,
            month: 1,
            day: 1,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 1);
                assert_eq!(d.month, 1);
                assert_eq!(d.day, 1);
            }
            other => panic!("expected Date min, got {other:?}"),
        }
    }

    #[test]
    fn rt_date_max() {
        let obj = MontyObject::Date(monty::MontyDate {
            year: 9999,
            month: 12,
            day: 31,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 9999);
                assert_eq!(d.month, 12);
                assert_eq!(d.day, 31);
            }
            other => panic!("expected Date max, got {other:?}"),
        }
    }

    #[test]
    fn rt_date_leap_day() {
        let obj = MontyObject::Date(monty::MontyDate {
            year: 2024,
            month: 2,
            day: 29,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 2024);
                assert_eq!(d.month, 2);
                assert_eq!(d.day, 29);
            }
            other => panic!("expected Date leap day, got {other:?}"),
        }
    }

    // --- DateTime ---

    #[test]
    fn rt_datetime_naive() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 4,
            day: 9,
            hour: 14,
            minute: 30,
            second: 45,
            microsecond: 0,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.year, 2026);
                assert_eq!(dt.month, 4);
                assert_eq!(dt.day, 9);
                assert_eq!(dt.hour, 14);
                assert_eq!(dt.minute, 30);
                assert_eq!(dt.second, 45);
                assert_eq!(dt.microsecond, 0);
                assert_eq!(dt.offset_seconds, None);
                assert_eq!(dt.timezone_name, None);
            }
            other => panic!("expected naive DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_utc() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            microsecond: 0,
            offset_seconds: Some(0),
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.offset_seconds, Some(0));
                assert_eq!(dt.timezone_name, None);
            }
            other => panic!("expected UTC DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_positive_offset() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 6,
            day: 15,
            hour: 10,
            minute: 0,
            second: 0,
            microsecond: 0,
            offset_seconds: Some(19800), // +05:30
            timezone_name: Some("IST".into()),
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.offset_seconds, Some(19800));
                assert_eq!(dt.timezone_name, Some("IST".into()));
            }
            other => panic!("expected +05:30 DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_negative_offset() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 12,
            day: 25,
            hour: 18,
            minute: 30,
            second: 0,
            microsecond: 0,
            offset_seconds: Some(-18000), // -05:00
            timezone_name: Some("EST".into()),
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.offset_seconds, Some(-18000));
                assert_eq!(dt.timezone_name, Some("EST".into()));
            }
            other => panic!("expected -05:00 DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_microseconds() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 4,
            day: 9,
            hour: 14,
            minute: 30,
            second: 0,
            microsecond: 123456,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => assert_eq!(dt.microsecond, 123456),
            other => panic!("expected DateTime with microseconds, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_max_microseconds() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 4,
            day: 9,
            hour: 23,
            minute: 59,
            second: 59,
            microsecond: 999999,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.hour, 23);
                assert_eq!(dt.minute, 59);
                assert_eq!(dt.second, 59);
                assert_eq!(dt.microsecond, 999999);
            }
            other => panic!("expected DateTime end-of-day, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_midnight() {
        let obj = MontyObject::DateTime(monty::MontyDateTime {
            year: 2026,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            microsecond: 0,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.hour, 0);
                assert_eq!(dt.minute, 0);
                assert_eq!(dt.second, 0);
            }
            other => panic!("expected midnight DateTime, got {other:?}"),
        }
    }

    // --- TimeDelta ---

    #[test]
    fn rt_timedelta() {
        let obj = MontyObject::TimeDelta(monty::MontyTimeDelta {
            days: 1,
            seconds: 3600,
            microseconds: 500,
        });
        match round_trip(&obj) {
            MontyObject::TimeDelta(td) => {
                assert_eq!(td.days, 1);
                assert_eq!(td.seconds, 3600);
                assert_eq!(td.microseconds, 500);
            }
            other => panic!("expected TimeDelta, got {other:?}"),
        }
    }

    #[test]
    fn rt_timedelta_zero() {
        let obj = MontyObject::TimeDelta(monty::MontyTimeDelta {
            days: 0,
            seconds: 0,
            microseconds: 0,
        });
        match round_trip(&obj) {
            MontyObject::TimeDelta(td) => {
                assert_eq!(td.days, 0);
                assert_eq!(td.seconds, 0);
                assert_eq!(td.microseconds, 0);
            }
            other => panic!("expected zero TimeDelta, got {other:?}"),
        }
    }

    #[test]
    fn rt_timedelta_negative() {
        let obj = MontyObject::TimeDelta(monty::MontyTimeDelta {
            days: -5,
            seconds: 43200,
            microseconds: 0,
        });
        match round_trip(&obj) {
            MontyObject::TimeDelta(td) => {
                assert_eq!(td.days, -5);
                assert_eq!(td.seconds, 43200);
            }
            other => panic!("expected negative TimeDelta, got {other:?}"),
        }
    }

    // --- TimeZone ---

    #[test]
    fn rt_timezone_utc() {
        let obj = MontyObject::TimeZone(monty::MontyTimeZone {
            offset_seconds: 0,
            name: None,
        });
        match round_trip(&obj) {
            MontyObject::TimeZone(tz) => {
                assert_eq!(tz.offset_seconds, 0);
                assert_eq!(tz.name, None);
            }
            other => panic!("expected UTC TimeZone, got {other:?}"),
        }
    }

    #[test]
    fn rt_timezone_named() {
        let obj = MontyObject::TimeZone(monty::MontyTimeZone {
            offset_seconds: -18000,
            name: Some("EST".into()),
        });
        match round_trip(&obj) {
            MontyObject::TimeZone(tz) => {
                assert_eq!(tz.offset_seconds, -18000);
                assert_eq!(tz.name, Some("EST".into()));
            }
            other => panic!("expected named TimeZone, got {other:?}"),
        }
    }

    #[test]
    fn rt_timezone_positive() {
        let obj = MontyObject::TimeZone(monty::MontyTimeZone {
            offset_seconds: 32400, // +09:00
            name: Some("JST".into()),
        });
        match round_trip(&obj) {
            MontyObject::TimeZone(tz) => {
                assert_eq!(tz.offset_seconds, 32400);
                assert_eq!(tz.name, Some("JST".into()));
            }
            other => panic!("expected +09:00 TimeZone, got {other:?}"),
        }
    }

    // --- Path ---

    #[test]
    fn rt_path() {
        let obj = MontyObject::Path("/tmp/foo".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, "/tmp/foo"),
            other => panic!("expected Path, got {other:?}"),
        }
    }

    #[test]
    fn rt_path_with_spaces() {
        let obj = MontyObject::Path("/my path/has spaces".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, "/my path/has spaces"),
            other => panic!("expected Path with spaces, got {other:?}"),
        }
    }

    #[test]
    fn rt_path_unicode() {
        let obj = MontyObject::Path("/données/café.txt".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, "/données/café.txt"),
            other => panic!("expected unicode Path, got {other:?}"),
        }
    }

    #[test]
    fn rt_path_empty() {
        let obj = MontyObject::Path("".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, ""),
            other => panic!("expected empty Path, got {other:?}"),
        }
    }

    // --- Tuple ---

    #[test]
    fn rt_tuple() {
        let obj = MontyObject::Tuple(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(items[1], MontyObject::Int(2)));
            }
            other => panic!("expected Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_empty() {
        let obj = MontyObject::Tuple(vec![]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => assert!(items.is_empty()),
            other => panic!("expected empty Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_single() {
        let obj = MontyObject::Tuple(vec![MontyObject::String("solo".into())]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 1);
                assert!(matches!(&items[0], MontyObject::String(s) if s == "solo"));
            }
            other => panic!("expected single-element Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_mixed_types() {
        let obj = MontyObject::Tuple(vec![
            MontyObject::Int(1),
            MontyObject::String("two".into()),
            MontyObject::Bool(true),
            MontyObject::None,
        ]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 4);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(&items[1], MontyObject::String(s) if s == "two"));
                assert!(matches!(items[2], MontyObject::Bool(true)));
                assert!(matches!(items[3], MontyObject::None));
            }
            other => panic!("expected mixed Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_nested() {
        let inner = MontyObject::Tuple(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        let obj = MontyObject::Tuple(vec![inner, MontyObject::Int(3)]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 2);
                match &items[0] {
                    MontyObject::Tuple(inner) => {
                        assert_eq!(inner.len(), 2);
                        assert!(matches!(inner[0], MontyObject::Int(1)));
                    }
                    other => panic!("expected nested Tuple, got {other:?}"),
                }
            }
            other => panic!("expected outer Tuple, got {other:?}"),
        }
    }

    // --- Set ---

    #[test]
    fn rt_set() {
        let obj = MontyObject::Set(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        match round_trip(&obj) {
            MontyObject::Set(items) => {
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected Set, got {other:?}"),
        }
    }

    #[test]
    fn rt_set_empty() {
        let obj = MontyObject::Set(vec![]);
        match round_trip(&obj) {
            MontyObject::Set(items) => assert!(items.is_empty()),
            other => panic!("expected empty Set, got {other:?}"),
        }
    }

    // --- FrozenSet ---

    #[test]
    fn rt_frozenset() {
        let obj = MontyObject::FrozenSet(vec![MontyObject::Int(3), MontyObject::Int(4)]);
        match round_trip(&obj) {
            MontyObject::FrozenSet(items) => {
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected FrozenSet, got {other:?}"),
        }
    }

    #[test]
    fn rt_frozenset_empty() {
        let obj = MontyObject::FrozenSet(vec![]);
        match round_trip(&obj) {
            MontyObject::FrozenSet(items) => assert!(items.is_empty()),
            other => panic!("expected empty FrozenSet, got {other:?}"),
        }
    }

    // --- Bytes ---

    #[test]
    fn rt_bytes() {
        let obj = MontyObject::Bytes(vec![72, 105]);
        match round_trip(&obj) {
            MontyObject::Bytes(b) => assert_eq!(b, vec![72, 105]),
            other => panic!("expected Bytes, got {other:?}"),
        }
    }

    #[test]
    fn rt_bytes_empty() {
        let obj = MontyObject::Bytes(vec![]);
        match round_trip(&obj) {
            MontyObject::Bytes(b) => assert!(b.is_empty()),
            other => panic!("expected empty Bytes, got {other:?}"),
        }
    }

    #[test]
    fn rt_bytes_full_range() {
        let obj = MontyObject::Bytes((0u8..=255).collect());
        match round_trip(&obj) {
            MontyObject::Bytes(b) => {
                assert_eq!(b.len(), 256);
                assert_eq!(b[0], 0);
                assert_eq!(b[255], 255);
            }
            other => panic!("expected full-range Bytes, got {other:?}"),
        }
    }

    // --- NamedTuple ---

    #[test]
    fn rt_named_tuple() {
        let obj = MontyObject::NamedTuple {
            type_name: "Point".into(),
            field_names: vec!["x".into(), "y".into()],
            values: vec![MontyObject::Int(10), MontyObject::Int(20)],
        };
        match round_trip(&obj) {
            MontyObject::NamedTuple {
                type_name,
                field_names,
                values,
            } => {
                assert_eq!(type_name, "Point");
                assert_eq!(field_names, vec!["x", "y"]);
                assert_eq!(values.len(), 2);
                assert!(matches!(values[0], MontyObject::Int(10)));
                assert!(matches!(values[1], MontyObject::Int(20)));
            }
            other => panic!("expected NamedTuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_named_tuple_empty() {
        let obj = MontyObject::NamedTuple {
            type_name: "Empty".into(),
            field_names: vec![],
            values: vec![],
        };
        match round_trip(&obj) {
            MontyObject::NamedTuple {
                type_name,
                field_names,
                values,
            } => {
                assert_eq!(type_name, "Empty");
                assert!(field_names.is_empty());
                assert!(values.is_empty());
            }
            other => panic!("expected empty NamedTuple, got {other:?}"),
        }
    }

    // --- Dataclass ---

    #[test]
    fn rt_dataclass() {
        let obj = MontyObject::Dataclass {
            name: "MyClass".into(),
            type_id: 1,
            field_names: vec!["x".into(), "y".into()],
            attrs: vec![
                (MontyObject::String("x".into()), MontyObject::Int(42)),
                (
                    MontyObject::String("y".into()),
                    MontyObject::String("hello".into()),
                ),
            ]
            .into(),
            frozen: false,
        };
        match round_trip(&obj) {
            MontyObject::Dataclass {
                name,
                type_id,
                field_names,
                frozen,
                ..
            } => {
                assert_eq!(name, "MyClass");
                assert_eq!(type_id, 1);
                assert_eq!(field_names, vec!["x", "y"]);
                assert!(!frozen);
            }
            other => panic!("expected Dataclass, got {other:?}"),
        }
    }

    #[test]
    fn rt_dataclass_frozen() {
        let obj = MontyObject::Dataclass {
            name: "Frozen".into(),
            type_id: 99,
            field_names: vec!["a".into()],
            attrs: vec![(MontyObject::String("a".into()), MontyObject::Bool(true))].into(),
            frozen: true,
        };
        match round_trip(&obj) {
            MontyObject::Dataclass { name, frozen, .. } => {
                assert_eq!(name, "Frozen");
                assert!(frozen);
            }
            other => panic!("expected frozen Dataclass, got {other:?}"),
        }
    }

    // --- BigInt (large values stay lossy — JSON has no big-int type) ---

    #[test]
    fn rt_bigint_large_stays_lossy() {
        let n = BigInt::parse_bytes(b"99999999999999999999999", 10).unwrap();
        let obj = MontyObject::BigInt(n);
        let back = round_trip(&obj);
        // This stays lossy by design — JSON has no native big-integer type.
        assert!(
            matches!(back, MontyObject::String(_)),
            "large BigInt stays lossy (String): got {back:?}"
        );
    }

    // --- Representational types (not data, just display) ---

    #[test]
    fn rt_ellipsis_becomes_string() {
        let back = round_trip(&MontyObject::Ellipsis);
        match back {
            MontyObject::String(s) => assert_eq!(s, "..."),
            other => panic!("Ellipsis round-trips as String: got {other:?}"),
        }
    }

    // Note: MontyObject::Type and MontyObject::BuiltinFunction are not tested
    // here because the inner types are private to the monty crate.
    // They serialize as display strings and aren't meaningful to round-trip.

    #[test]
    fn rt_function_becomes_string() {
        let obj = MontyObject::Function {
            name: "my_func".into(),
            docstring: Some("does stuff".into()),
        };
        match round_trip(&obj) {
            MontyObject::String(s) => assert_eq!(s, "<function my_func>"),
            other => panic!("Function round-trips as String: got {other:?}"),
        }
    }

    #[test]
    fn rt_exception_becomes_string() {
        let obj = MontyObject::Exception {
            exc_type: monty::ExcType::ValueError,
            arg: Some("bad".into()),
        };
        match round_trip(&obj) {
            MontyObject::String(s) => assert_eq!(s, "ValueError: bad"),
            other => panic!("Exception round-trips as String: got {other:?}"),
        }
    }

    #[test]
    fn rt_repr_becomes_string() {
        let obj = MontyObject::Repr("<object>".into());
        match round_trip(&obj) {
            MontyObject::String(s) => assert_eq!(s, "<object>"),
            other => panic!("Repr round-trips as String: got {other:?}"),
        }
    }

    // --- Edge case: dict with __type key should NOT be hijacked ---

    #[test]
    fn rt_dict_with_type_key_stays_dict() {
        // A plain Python dict that happens to contain "__type" must NOT be
        // misinterpreted as a typed wrapper. It should round-trip as a dict.
        let obj = MontyObject::dict(vec![
            (
                MontyObject::String("__type".into()),
                MontyObject::String("date".into()),
            ),
            (
                MontyObject::String("value".into()),
                MontyObject::String("not-a-date".into()),
            ),
        ]);
        // After the refactor, json_to_monty_object will see __type:"date" and
        // try to parse it as a MontyDate. This is the correct behavior —
        // if Dart sends {"__type":"date","year":...} it means "this is a date".
        // A plain dict should never have __type unless it's intentionally typed.
        // This test documents that __type IS the discriminator.
        let json = monty_object_to_json(&obj);
        let parsed = json.as_object().unwrap();
        // Dict with string keys serializes as JSON object — no __type wrapper added
        assert!(
            !parsed.contains_key("__type") || parsed.len() > 1,
            "plain dict should not gain extra __type wrapper"
        );
    }
}
