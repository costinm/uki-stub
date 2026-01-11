const std = @import("std");
const ed25519 = std.crypto.sign.Ed25519;

pub fn verify(public_key_bytes: []const u8, signature_bytes: []const u8, content: []const u8) !bool {
    if (public_key_bytes.len != 32) {
        return error.InvalidPublicKeyLength;
    }
    if (signature_bytes.len != 64) {
        return error.InvalidSignatureLength;
    }

    var pk_bytes: [32]u8 = undefined;
    std.mem.copyForwards(u8, &pk_bytes, public_key_bytes);

    var sig_bytes: [64]u8 = undefined;
    std.mem.copyForwards(u8, &sig_bytes, signature_bytes);

    const public_key = try ed25519.PublicKey.fromBytes(pk_bytes);
    const signature = ed25519.Signature.fromBytes(sig_bytes);

    signature.verify(content, public_key) catch |err| switch (err) {
        error.SignatureVerificationFailed => return false,
        else => return err,
    };
    return true;
}

test "verify signature" {
    const testing = std.testing;

    // 1. Generate a new keypair
    const seed: [32]u8 = [_]u8{0} ** 32; // Use deterministic seed for testing
    const key_pair = try ed25519.KeyPair.generateDeterministic(seed);
    const public_key = key_pair.public_key;

    // 2. Create a message to sign
    const message = "This is a test message.";

    // 3. Sign the message
    const signature = try key_pair.sign(message, null);

    // 4. Verify the signature
    const public_key_slice = std.mem.asBytes(&public_key);
    const signature_slice = std.mem.asBytes(&signature);
    const is_valid = try verify(public_key_slice, signature_slice, message);
    try testing.expect(is_valid);

    // 5. Test with invalid signature
    var invalid_signature = signature;
    invalid_signature.s[0] +%= 1; // Tamper with the signature
    const invalid_signature_slice = std.mem.asBytes(&invalid_signature);
    const is_invalid = try verify(public_key_slice, invalid_signature_slice, message);
    try testing.expect(!is_invalid);
}