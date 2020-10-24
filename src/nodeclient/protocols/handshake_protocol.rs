use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;

use byteorder::{ByteOrder, NetworkEndian, WriteBytesExt};
use serde_cbor::{de, ser, Value};

pub fn ping(mut stream: &TcpStream, start_time: u32, network_magic: u32) -> Result<String, String> {
    let mut handshake: Vec<u8> = Vec::new();
    handshake.write_u32::<NetworkEndian>(start_time).unwrap(); // timestamp
    handshake.write_u16::<NetworkEndian>(0u16).unwrap(); // handshake protocol id

    let payload = msg_propose_versions(network_magic);
    handshake.write_u16::<NetworkEndian>(payload.len() as u16).unwrap(); // length of payload
    handshake.write(&payload[..]).unwrap(); // the payload
    // println!("sending: {:?}", hex::encode(&handshake));

    // send the message. Expect it to succeed.
    stream.write(&handshake).unwrap();

    let mut response = [0u8; 8]; // read 8 bytes to start with
    return match stream.read_exact(&mut response) {
        Ok(_) => {
            let _server_timestamp = NetworkEndian::read_u32(&mut response[0..4]);
            // println!("server_timestamp: {:x}", server_timestamp);
            let _protocol_id = NetworkEndian::read_u16(&mut response[4..6]);
            // println!("protocol_id: {:x}", protocol_id);
            let payload_length = NetworkEndian::read_u16(&mut response[6..]) as usize;
            // println!("payload_length: {:x}", payload_length);
            let mut response = vec![0u8; payload_length];
            match stream.read_exact(&mut response) {
                Ok(_) => {
                    if payload_length != 8 {
                        // some payload error
                        let cbor_value: Value = de::from_slice(&response[..]).unwrap();
                        match get_ping_error_message(&cbor_value) {
                            Ok(error_message) => {
                                Err(error_message)
                            }
                            Err(_) => {
                                Err(format!("Unable to parse payload error! {}", hex::encode(response)))
                            }
                        }
                    } else {
                        Ok(hex::encode(response))
                    }
                }
                Err(e) => {
                    Err(format!("Unable to read response payload! {}", e))
                }
            }
        }
        Err(e) => {
            Err(format!("Unable to read response header! {}", e))
        }
    };
}

// Serialize cbor for MsgProposeVersions
//
// Create the byte representation of MsgProposeVersions for sending to the server
fn msg_propose_versions(network_magic: u32) -> Vec<u8> {
    let mut payload_map: BTreeMap<Value, Value> = BTreeMap::new();
    // protocol version 3 mapped to the network_magic value
    payload_map.insert(Value::Integer(0x03), Value::Integer(network_magic as i128));

    let msg_propose_versions = Value::Array(vec![
        Value::Integer(0), // message_id
        Value::Map(payload_map)
    ]);

    ser::to_vec_packed(&msg_propose_versions).unwrap()
}

fn get_ping_error_message(cbor_value: &Value) -> Result<String, ()> {
    match cbor_value {
        Value::Text(cbor_text) => {
            return Ok(cbor_text.to_owned());
        }
        Value::Array(cbor_array) => {
            for value in cbor_array {
                let result = get_ping_error_message(value);
                if result.is_ok() {
                    return result;
                }
            }
        }
        _ => {}
    }
    return Err(());
}