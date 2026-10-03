'use strict'

const { X509Certificate } = require('node:crypto')
const cbor = require('cbor')

function fail(code, status = 401) { const error = new Error(code); error.code = code; error.statusCode = status; throw error }
function decodeProof(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length > 32_000) fail('invalid_attestation_encoding')
  const bytes = Buffer.from(value, 'base64')
  if (bytes.toString('base64') !== value) fail('invalid_attestation_encoding')
  let decoded
  try { decoded = cbor.decodeAllSync(bytes, { max_depth: 12, preventDuplicateKeys: true }) } catch { fail('invalid_attestation_encoding') }
  if (decoded.length !== 1 || !decoded[0] || typeof decoded[0] !== 'object') fail('invalid_attestation_encoding')
  return { bytes, decoded: decoded[0] }
}

// node-app-attest pins Apple's App Attestation Root CA and implements Apple's
// nonce/credential/RP hash/AAGUID/key/signature checks. This adapter additionally
// enforces strict single-object CBOR, certificate ordering/validity and lengths.
// A valid assertion is app-instance proof only; auth.js also requires Apple identity.
function createAttestationVerifier({ teamId, bundleId, environment = 'production', now = Date.now }) {
  if (!/^[A-Z0-9]{10}$/.test(teamId || '') || !bundleId || !['production', 'development'].includes(environment)) {
    fail('app_attest_not_configured', 503)
  }
  const config = { teamIdentifier: teamId, bundleIdentifier: bundleId }
  async function verifyAttestation({ attestation, keyID, payload }) {
    const { bytes, decoded } = decodeProof(attestation)
    if (decoded.fmt !== 'apple-appattest' || decoded.attStmt?.x5c?.length !== 2 ||
        !Buffer.isBuffer(decoded.authData) || decoded.authData.length < 87 ||
        decoded.authData.readUInt16BE(53) !== 32 ||
        !/^[A-Za-z0-9+/]{43}=$/.test(keyID || '')) fail('invalid_attestation')
    try {
      const [leaf, intermediate] = decoded.attStmt.x5c.map((value) => new X509Certificate(value))
      if (leaf.ca || !intermediate.ca || !leaf.checkIssued(intermediate)) fail('invalid_attestation_chain')
      for (const cert of [leaf, intermediate]) {
        if (Date.parse(cert.validFrom) > now() || Date.parse(cert.validTo) < now()) fail('expired_attestation_certificate')
      }
      const library = await import('node-app-attest')
      const result = library.verifyAttestation({ ...config, attestation: bytes, challenge: payload,
        keyId: keyID, allowDevelopmentEnvironment: environment === 'development' })
      if (result.environment !== environment) fail('attestation_environment_mismatch')
      return { keyID, publicKey: result.publicKey, signCount: 0, environment: result.environment }
    } catch (error) {
      if (error.statusCode) throw error
      fail('invalid_attestation')
    }
  }
  async function verifyAssertion({ assertion, payload, device }) {
    const { bytes, decoded } = decodeProof(assertion)
    if (!Buffer.isBuffer(decoded.authenticatorData) || decoded.authenticatorData.length !== 37 ||
        !Buffer.isBuffer(decoded.signature) || decoded.signature.length < 64 || decoded.signature.length > 80 ||
        !Number.isSafeInteger(device.signCount) || device.signCount < 0 || device.environment !== environment) {
      fail('invalid_assertion')
    }
    // The pinned library uses signed int32; reject exhaustion rather than wrap.
    if (decoded.authenticatorData.readUInt32BE(33) > 0x7fffffff) fail('attestation_key_rotation_required')
    try {
      const library = await import('node-app-attest')
      return library.verifyAssertion({ ...config, assertion: bytes, payload,
        publicKey: device.publicKey, signCount: device.signCount })
    } catch { fail('invalid_assertion') }
  }
  return { verifyAttestation, verifyAssertion }
}

module.exports = { createAttestationVerifier }
