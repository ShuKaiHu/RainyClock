'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { generateKeyPairSync, createHash, sign, X509Certificate, randomBytes } = require('node:crypto')
const { mkdtempSync, writeFileSync, readFileSync, rmSync } = require('node:fs')
const { join } = require('node:path')
const { tmpdir } = require('node:os')
const { execFileSync } = require('node:child_process')
const cbor = require('cbor')
const { createAppleVerifier } = require('../membership/apple')
const { createAttestationVerifier } = require('../membership/attestation')
const { createMembershipAuth, requestPayload, sha256 } = require('../membership/auth')
const { createLevelPlayVerifier } = require('../membership/rewards')
const { createMemoryStore } = require('../membership/store')

const bundleId = 'com.shukaihu.RainyClock'
const teamId = 'MQJ88U9NAJ'
const products = { 'test.monthly': 'monthly', 'test.yearly': 'yearly', 'test.lifetime': 'lifetime' }
const deviceVerificationID = 'a28e90b1-8c9f-4114-ab75-f3b25c11c8fa'
const nonce = 'b5a26156-aaf3-473a-83f4-bc38b8f76d7b'
let fixture

// Locally generated, clearly test-only roots. These exercise the actual official
// Apple certificate-chain and JWS implementation, with offline Sandbox checks.
// Never install these roots in a deployed service; no Apple credentials involved.
function makeSigningFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'rainyclock-apple-test-'))
  const openssl = (...args) => execFileSync('openssl', args, { cwd: dir, stdio: 'ignore' })
  const write = (name, value) => writeFileSync(join(dir, name), value)
  try {
    for (const name of ['root', 'intermediate', 'leaf']) {
      const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
      write(`${name}.key`, pair.privateKey.export({ type: 'pkcs8', format: 'pem' }))
    }
    write('root.cnf', '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=RainyClock Test Root ONLY\n[ext]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n')
    openssl('req', '-x509', '-new', '-key', 'root.key', '-out', 'root.pem', '-days', '2', '-config', 'root.cnf')
    for (const [name, parent, extensions] of [
      ['intermediate', 'root', 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n1.2.840.113635.100.6.2.1=DER:05:00'],
      ['leaf', 'intermediate', 'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n1.2.840.113635.100.6.11.1=DER:05:00']
    ]) {
      openssl('req', '-new', '-key', `${name}.key`, '-out', `${name}.csr`, '-subj', `/CN=RainyClock Test ${name} ONLY`)
      write(`${name}.ext`, extensions)
      openssl('x509', '-req', '-in', `${name}.csr`, '-CA', `${parent}.pem`, '-CAkey', `${parent}.key`,
        '-CAcreateserial', '-out', `${name}.pem`, '-days', '2', '-extfile', `${name}.ext`)
    }
    const root = readFileSync(join(dir, 'root.pem'))
    const chain = ['leaf', 'intermediate', 'root'].map((name) => new X509Certificate(readFileSync(join(dir, `${name}.pem`))).raw.toString('base64'))
    const key = readFileSync(join(dir, 'leaf.key'))
    const jws = (payload) => {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', x5c: chain })).toString('base64url')
      const content = `${header}.${Buffer.from(JSON.stringify(payload)).toString('base64url')}`
      return `${content}.${sign('sha256', Buffer.from(content), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`
    }
    return { root, jws }
  } finally { rmSync(dir, { recursive: true, force: true }) }
}

test.before(() => { fixture = makeSigningFixture() })
function verifier(options = {}) {
  return createAppleVerifier({ environment: 'Sandbox', bundleId, rootCertificates: [fixture.root],
    products, enableOnlineChecks: false, ...options })
}
function appPayload(overrides = {}) {
  return { receiptType: 'Sandbox', bundleId, appTransactionId: 'app-123', receiptCreationDate: Date.now(),
    originalPurchaseDate: Date.now() - 10000, deviceVerificationNonce: nonce,
    deviceVerification: createHash('sha384').update(nonce + deviceVerificationID).digest('base64'), ...overrides }
}
function txPayload(overrides = {}) {
  return { environment: 'Sandbox', bundleId, appTransactionId: 'app-123', transactionId: 'tx-123',
    originalTransactionId: 'otx-123', productId: 'test.monthly', type: 'Auto-Renewable Subscription',
    purchaseDate: Date.now() - 1000, signedDate: Date.now(), expiresDate: Date.now() + 100000,
    inAppOwnershipType: 'PURCHASED', ...overrides }
}

test('Apple verification validates a cryptographic chain, signed AppTransaction and device binding', async () => {
  const apple = verifier()
  const proof = fixture.jws(appPayload())
  assert.equal((await apple.verifyAppTransaction(proof, deviceVerificationID)).appTransactionId, 'app-123')
  await assert.rejects(apple.verifyAppTransaction(proof, nonce), /device_verification_failed/)
  const parts = proof.split('.')
  parts[1] = Buffer.from(JSON.stringify(appPayload({ appTransactionId: 'victim' }))).toString('base64url')
  await assert.rejects(apple.verifyAppTransaction(parts.join('.'), deviceVerificationID), /invalid_apple_proof/)
})

function equivalentECDSASignature(jws) {
  const parts = jws.split('.')
  const signature = Buffer.from(parts[2], 'base64url')
  const order = BigInt('0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551')
  const otherS = order - BigInt(`0x${signature.subarray(32).toString('hex')}`)
  Buffer.from(otherS.toString(16).padStart(64, '0'), 'hex').copy(signature, 32)
  parts[2] = signature.toString('base64url')
  return parts.join('.')
}

test('Apple proof replay fingerprint is invariant under equivalent ECDSA signatures', async () => {
  const apple = verifier()
  const original = fixture.jws(appPayload())
  const alternate = equivalentECDSASignature(original)
  assert.notEqual(original, alternate)
  const first = await apple.verifyAppTransaction(original, deviceVerificationID)
  const second = await apple.verifyAppTransaction(alternate, deviceVerificationID)
  assert.equal(first.proofId, second.proofId)
})

test('Apple proof rejects wrong bundle, environment, stale bootstrap and missing stable identity', async () => {
  const apple = verifier()
  for (const payload of [appPayload({ bundleId: 'other.app' }), appPayload({ receiptType: 'Production' })]) {
    await assert.rejects(apple.verifyAppTransaction(fixture.jws(payload), deviceVerificationID), /invalid_apple_proof/)
  }
  await assert.rejects(verifier({ now: () => Date.now() + 360000 }).verifyAppTransaction(fixture.jws(appPayload()), deviceVerificationID), /refresh_required/)
  await assert.rejects(apple.verifyAppTransaction(fixture.jws(appPayload({ appTransactionId: undefined })), deviceVerificationID), /id_unavailable/)
})

test('Apple verifier rejects unsigned local modes and missing roots or disabled production revocation checks', () => {
  assert.throws(() => verifier({ environment: 'Xcode' }), /not_allowed/)
  assert.throws(() => verifier({ environment: 'LocalTesting' }), /not_allowed/)
  assert.throws(() => verifier({ rootCertificates: [] }), /not_configured/)
  assert.throws(() => verifier({ environment: 'Production', appAppleId: 123 }), /not_configured/)
})

test('purchase verification checks product and type, preserving revocation fields', async () => {
  const apple = verifier()
  const revoked = await apple.verifyTransaction(fixture.jws(txPayload({ revocationDate: Date.now() })))
  assert.ok(revoked.revocationDate)
  assert.equal(revoked.bundleId, bundleId)
  await assert.rejects(apple.verifyTransaction(fixture.jws(txPayload({ productId: 'fake' }))), /unknown_product/)
  await assert.rejects(apple.verifyTransaction(fixture.jws(txPayload({ type: 'Consumable' }))), /unexpected_product_type/)
  await assert.rejects(apple.verifyTransaction(fixture.jws(txPayload({ inAppOwnershipType: 'FAMILY_SHARED' }))), /family_sharing/)
})

test('Server Notifications V2 verifies outer and nested signatures and transaction linkage', async () => {
  const apple = verifier()
  const event = { notificationUUID: 'event-123', notificationType: 'DID_RENEW', signedDate: Date.now(),
    data: { bundleId, environment: 'Sandbox', signedTransactionInfo: fixture.jws(txPayload()),
      signedRenewalInfo: fixture.jws({ environment: 'Sandbox', originalTransactionId: 'otx-123', signedDate: Date.now() }) } }
  assert.equal((await apple.verifyNotification(fixture.jws(event))).transaction.transactionId, 'tx-123')
  event.data.signedRenewalInfo = fixture.jws({ environment: 'Sandbox', originalTransactionId: 'other', signedDate: Date.now() })
  await assert.rejects(apple.verifyNotification(fixture.jws(event)), /mismatch/)
  event.data.signedTransactionInfo = 'fake.fake.fake'
  await assert.rejects(apple.verifyNotification(fixture.jws(event)), /invalid_apple_proof/)
})

test('verified renewal notifications expose preferences separately from transaction dates and reject untrusted renewal', async () => {
  const now = Date.now()
  const apple = verifier({ now: () => now })
  const renewal = { environment: 'Sandbox', originalTransactionId: 'otx-123', signedDate: now,
    autoRenewStatus: 0, autoRenewProductId: 'test.yearly' }
  const event = (value) => fixture.jws({ notificationUUID: 'renewal-preference', notificationType: 'DID_CHANGE_RENEWAL_STATUS',
    signedDate: now, data: { bundleId, environment: 'Sandbox', status: 1,
      signedTransactionInfo: fixture.jws(txPayload({ signedDate: now - 1000 })), signedRenewalInfo: fixture.jws(value) } })
  const result = await apple.verifyNotification(event(renewal))
  assert.equal(result.transaction.autoRenewStatus, 0)
  assert.equal(result.transaction.autoRenewProductId, 'test.yearly')
  assert.equal(result.transaction.renewalSignedAt, now)
  assert.equal(result.transaction.status, 1, 'cancelled renewal remains active during the paid period')
  const unknown = await apple.verifyNotification(event({ ...renewal, autoRenewStatus: undefined, autoRenewProductId: 'unknown.product' }))
  assert.equal(unknown.transaction.autoRenewStatus, null)
  assert.equal(unknown.transaction.autoRenewProductId, null)
  await assert.rejects(apple.verifyNotification(event({ ...renewal, signedDate: now + 120_000 })), /invalid_renewal_date/)
  await assert.rejects(apple.verifyNotification(event({ ...renewal, signedDate: undefined })), /invalid_renewal_date/)
})

test('authoritative reconciliation includes refunds and applies latest subscription status', async () => {
  const apiClient = {
    async getTransactionHistory(id, revision) {
      assert.equal(id, 'app-123'); assert.equal(revision, null)
      return { environment: 'Sandbox', bundleId, hasMore: false, signedTransactions: [
        fixture.jws(txPayload()), fixture.jws(txPayload({ transactionId: 'lifetime', productId: 'test.lifetime',
          type: 'Non-Consumable', expiresDate: undefined, revocationDate: Date.now() }))] }
    },
    async getAllSubscriptionStatuses() {
      return { environment: 'Sandbox', bundleId, data: [{ lastTransactions: [{ status: 5,
        signedTransactionInfo: fixture.jws(txPayload()), signedRenewalInfo: fixture.jws({
          environment: 'Sandbox', originalTransactionId: 'otx-123', signedDate: Date.now(), autoRenewStatus: 0,
          autoRenewProductId: 'test.monthly' }) }] }] }
    }
  }
  const result = await verifier({ apiClient }).reconcile('app-123')
  assert.equal(result.transactions.length, 2)
  assert.ok(result.transactions.every((tx) => tx.revocationDate))
  const subscription = result.transactions.find((tx) => tx.productId === 'test.monthly')
  assert.equal(subscription.autoRenewStatus, 0)
  assert.equal(subscription.autoRenewProductId, 'test.monthly')
  assert.ok(subscription.renewalSignedAt)
  await assert.rejects(verifier().reconcile('app-123'), /not_configured/)
})

test('empty authoritative history is allowed but a 404 never masquerades as successful free reconciliation', async () => {
  const empty = verifier({ apiClient: { async getTransactionHistory() {
    return { environment: 'Sandbox', bundleId, hasMore: false, signedTransactions: [] }
  } } })
  assert.deepEqual((await empty.reconcile('app-123')).transactions, [])
  const missing = verifier({ apiClient: { async getTransactionHistory() {
    throw Object.assign(new Error('Transaction id not found.'), { httpStatusCode: 404, apiError: 4040010 })
  } } })
  await assert.rejects(missing.reconcile('app-123'), (error) => error.apiError === 4040010)
})

test('reconciliation rejects an otherwise signed transaction from another Apple member', async () => {
  const apple = verifier({ apiClient: { async getTransactionHistory() {
    return { environment: 'Sandbox', bundleId, hasMore: false,
      signedTransactions: [fixture.jws(txPayload({ appTransactionId: 'someone-else' }))] }
  } } })
  await assert.rejects(apple.reconcile('app-123'), /transaction_owner_mismatch/)
})

test('App Attest validates Apple-issued fixture, rejects wrong nonce, expired and mismatched environment', async () => {
  const historical = require('./fixtures/app-attest/attestation-development.json')
  const config = { teamId: 'V8H6LQ9448', bundleId: 'io.uebelacker.AppAttestExample',
    environment: 'development', now: () => Date.parse('2024-02-08T00:00:00Z') }
  const attest = createAttestationVerifier(config)
  const input = { attestation: historical.attestation, keyID: historical.keyId, payload: Buffer.from(historical.challenge, 'base64') }
  const device = await attest.verifyAttestation(input)
  assert.equal(device.signCount, 0)
  assert.match(device.publicKey, /BEGIN PUBLIC KEY/)
  await assert.rejects(attest.verifyAttestation({ ...input, payload: Buffer.from('different challenge') }), /invalid_attestation/)
  await assert.rejects(createAttestationVerifier({ ...config, now: Date.now }).verifyAttestation(input), /expired/)
  await assert.rejects(createAttestationVerifier({ ...config, environment: 'production' }).verifyAttestation(input), /invalid_attestation/)
})

function createDevice() {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  const keyID = randomBytes(32).toString('base64')
  const device = { keyID, publicKey: publicKey.export({ type: 'spki', format: 'pem' }), signCount: 0, environment: 'development' }
  const assertion = (payload, count = 1, app = `${teamId}.${bundleId}`) => {
    const authenticatorData = Buffer.alloc(37)
    createHash('sha256').update(app).digest().copy(authenticatorData)
    authenticatorData.writeUInt32BE(count, 33)
    const clientHash = createHash('sha256').update(payload).digest()
    const nonceBytes = createHash('sha256').update(Buffer.concat([authenticatorData, clientHash])).digest()
    return cbor.encode({ signature: sign('sha256', nonceBytes, privateKey), authenticatorData }).toString('base64')
  }
  return { keyID, device, assertion }
}
test('App Attest assertions bind cryptographic request, RP identity, increasing counter and one CBOR object', async () => {
  const verify = createAttestationVerifier({ teamId, bundleId, environment: 'development' })
  const { device, assertion } = createDevice()
  const payload = Buffer.from('bound request')
  assert.equal((await verify.verifyAssertion({ device, assertion: assertion(payload, 1), payload })).signCount, 1)
  await assert.rejects(verify.verifyAssertion({ device: { ...device, signCount: 1 }, assertion: assertion(payload, 1), payload }), /invalid_assertion/)
  await assert.rejects(verify.verifyAssertion({ device, assertion: assertion(payload, 2), payload: Buffer.from('tampered') }), /invalid_assertion/)
  await assert.rejects(verify.verifyAssertion({ device, assertion: assertion(payload, 2, 'other.bundle'), payload }), /invalid_assertion/)
  const doubled = Buffer.concat([Buffer.from(assertion(payload), 'base64'), cbor.encode({})]).toString('base64')
  await assert.rejects(verify.verifyAssertion({ device, assertion: doubled, payload }), /invalid_attestation_encoding/)
})

async function authFixture() {
  const store = createMemoryStore()
  const client = createDevice()
  const attestationVerifier = createAttestationVerifier({ teamId, bundleId, environment: 'development' })
  const auth = createMembershipAuth({ store, appleVerifier: verifier(), attestationVerifier })
  // Initial Apple attestation has its separate certificate-fixture test above.
  // Seed its already verified public key to exercise actual assertions end-to-end.
  await store.set(`authDevices/${sha256(client.keyID)}`, client.device)
  await store.set('members/member123', { id: 'member123' })
  const challenge = await auth.issueChallenge({ purpose: 'bootstrap', keyID: client.keyID })
  const signedAppTransaction = fixture.jws(appPayload())
  const rawBody = Buffer.from(JSON.stringify({ keyID: client.keyID, deviceVerificationID,
    signedAppTransaction, timeZone: 'Asia/Taipei' }))
  const path = '/v1/membership/session'
  const payload = requestPayload({ purpose: 'bootstrap', challenge, method: 'POST', path, rawBody })
  const headers = { 'x-rc-key-id': client.keyID, 'x-rc-challenge': challenge.id, 'x-rc-assertion': client.assertion(payload, 1) }
  const bootstrap = await auth.bootstrapIdentityAndDevice({ rawBody, headers, path })
  const session = await auth.issueSession({ memberId: 'member123', bootstrap })
  return { store, client, auth, session, signedAppTransaction }
}
async function authenticatedInput(state, count = 2) {
  const { client, auth, session } = state
  const challenge = await auth.issueChallenge({ purpose: 'request', keyID: client.keyID, sessionToken: session.token })
  const path = '/v1/membership/status', method = 'POST', rawBody = Buffer.from('{}')
  const payload = requestPayload({ purpose: 'request', challenge, method, path, rawBody })
  return { token: session.token, rawBody, method, path,
    headers: { 'x-rc-key-id': client.keyID, 'x-rc-challenge': challenge.id, 'x-rc-assertion': client.assertion(payload, count) } }
}
test('sessions store token hashes, assert identity AND app-instance, reject a concurrent replay atomically', async () => {
  const state = await authFixture()
  const stored = await state.store.list('authSessions')
  assert.equal(stored[0].id, sha256(state.session.token))
  assert.ok(!JSON.stringify(stored).includes(state.session.token))
  const input = await authenticatedInput(state)
  const results = await Promise.allSettled([state.auth.authenticate(input), state.auth.authenticate(input)])
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1)
  assert.equal(results.find((r) => r.status === 'fulfilled').value.memberId, 'member123')
})

async function rebootstrap(state, { client = state.client, signed = state.signedAppTransaction, count = 2 } = {}) {
  const challenge = await state.auth.issueChallenge({ purpose: 'bootstrap', keyID: client.keyID })
  const rawBody = Buffer.from(JSON.stringify({ keyID: client.keyID, deviceVerificationID, signedAppTransaction: signed, timeZone: 'Asia/Taipei' }))
  const path = '/v1/membership/session', method = 'POST'
  const payload = requestPayload({ purpose: 'bootstrap', challenge, method, path, rawBody })
  return state.auth.bootstrapIdentityAndDevice({ rawBody, method, path, headers: {
    'x-rc-key-id': client.keyID, 'x-rc-challenge': challenge.id, 'x-rc-assertion': client.assertion(payload, count)
  } })
}

test('another device cannot replay Apple proof by changing its equivalent JWS signature', async () => {
  const state = await authFixture()
  const another = createDevice()
  await state.store.set(`authDevices/${sha256(another.keyID)}`, another.device)
  await assert.rejects(rebootstrap(state, { client: another, count: 1,
    signed: equivalentECDSASignature(state.signedAppTransaction) }), /apple_proof_replayed_on_other_device/)
})

test('successful reauthentication permanently revokes older session epoch, including same-account return', async () => {
  const state = await authFixture()
  const oldInput = await authenticatedInput(state, 3)
  const bootstrap = await rebootstrap(state)
  const newSession = await state.auth.issueSession({ memberId: 'member123', bootstrap })
  assert.notEqual(newSession.token, state.session.token)
  await assert.rejects(state.auth.authenticate(oldInput), /invalid_session/)
  await assert.rejects(state.auth.issueChallenge({ purpose: 'request', keyID: state.client.keyID,
    sessionToken: state.session.token }), /invalid_session/)
  state.session = newSession
  assert.equal((await state.auth.authenticate(await authenticatedInput(state, 3))).memberId, 'member123')
})

test('deletion finds device during interrupted reauthentication and cannot issue a new session afterward', async () => {
  const state = await authFixture()
  const bootstrap = await rebootstrap(state)
  const path = `authDevices/${sha256(state.client.keyID)}`
  const pending = await state.store.get(path)
  assert.equal(pending.memberId, 'member123')
  assert.ok(pending.ttlAt instanceof Date)
  await state.store.set('members/member123', { deletedAt: Date.now() })
  await state.auth.deleteMemberAuth('member123')
  assert.equal(await state.store.get(path), null)
  await assert.rejects(state.auth.issueSession({ memberId: 'member123', bootstrap }), /member_deleted/)
})

test('request assertions fail after body/path/token tampering without granting access', async () => {
  const state = await authFixture()
  const input = await authenticatedInput(state)
  await assert.rejects(state.auth.authenticate({ ...input, rawBody: Buffer.from('{"paid":true}') }), /invalid_assertion/)
  await assert.rejects(state.auth.authenticate({ ...input, path: '/v1/membership/delete' }), /invalid_assertion/)
  await assert.rejects(state.auth.authenticate({ ...input, token: randomBytes(32).toString('base64url') }), /invalid_session/)
  assert.equal((await state.auth.authenticate(input)).memberId, 'member123')
})

test('deleted member cannot use a previously valid session and auth cleanup removes keys and tokens', async () => {
  const state = await authFixture()
  const input = await authenticatedInput(state)
  await state.store.set('members/member123', { deletedAt: Date.now() })
  await assert.rejects(state.auth.authenticate(input), /member_deleted/)
  await state.auth.deleteMemberAuth('member123')
  assert.equal((await state.store.list('authDevices')).length, 0)
  assert.equal((await state.store.list('authSessions')).length, 0)
})

test('reward identity is stable across concurrent requests, resolves server member and is removed on deletion', async () => {
  const { auth, store } = await authFixture()
  const identities = await Promise.all([auth.getRewardIdentity('member123'), auth.getRewardIdentity('member123')])
  assert.equal(identities[0].userId, identities[1].userId)
  assert.match(identities[0].userId, /^[a-f0-9]{48}$/)
  assert.equal(await auth.resolveRewardMember(identities[0].userId), 'member123')
  await assert.rejects(auth.resolveRewardMember('b'.repeat(48)), /unknown_reward_user/)
  await store.set('members/member123', { deletedAt: Date.now() })
  await auth.deleteMemberAuth('member123')
  await assert.rejects(auth.resolveRewardMember(identities[0].userId), /unknown_reward_user/)
  assert.equal((await store.list('authRewardUsers')).length, 0)
})

test('expired challenge is rejected independently of a valid session and assertion', async () => {
  const state = await authFixture()
  const input = await authenticatedInput(state)
  const path = `authChallenges/${input.headers['x-rc-challenge']}`
  await state.store.set(path, { ...await state.store.get(path), expiresAt: Date.now() - 1 })
  await assert.rejects(state.auth.authenticate(input), /invalid_challenge/)
})

test('LevelPlay verifies exact documented signature and ignores unsigned custom member/amount fields', () => {
  const privateKey = 'test-only-levelplay-private-key', now = Date.now()
  const verify = createLevelPlayVerifier({ privateKey, now: () => now })
  const query = new URLSearchParams({ userId: 'a'.repeat(48), eventId: 'evt_123', rewards: '1', timestamp: new Date(now).toISOString().slice(0, 16).replace(/\D/g, '') })
  const signature = createHash('md5').update(query.get('timestamp') + query.get('eventId') + query.get('userId') + '1' + privateKey).digest('hex')
  query.set('signature', signature)
  query.set('custom_memberId', 'victim'); query.set('dynamicUserId', 'victim'); query.set('custom_amount', '999')
  const result = verify.verify(query)
  assert.equal(result.rewardUserId, 'a'.repeat(48))
  assert.equal(result.amount, 1)
  assert.equal(result.acknowledgement, 'evt_123:OK')
  query.set('userId', 'b'.repeat(48))
  assert.throws(() => verify.verify(query), /invalid_reward_signature/)
})

test('LevelPlay rejects duplicate fields, invalid amounts and missing private key', () => {
  for (const privateKey of ['', '   ', '\n\t', undefined, null, 123456]) {
    assert.throws(() => createLevelPlayVerifier({ privateKey }), /not_configured/)
  }
  const verify = createLevelPlayVerifier({ privateKey: 'test-only-long-private-key' })
  assert.throws(() => verify.verify(new URLSearchParams('userId=x&userId=y')), /invalid_reward_callback/)
})

test('LevelPlay parses the official dashboard calendar timestamp in UTC and signs its original representation', () => {
  // Real dashboard timestamp shape/date; all IDs and key here are synthetic.
  const privateKey = 'calendar-fixture-only-key', timestamp = '202609211216'
  const now = Date.parse('2026-09-21T12:16:47.240Z')
  const query = new URLSearchParams({ userId: 'a'.repeat(48), eventId: 'calendar-fixture', rewards: '1', timestamp })
  const sign = (value) => createHash('md5').update(value + 'calendar-fixture' + 'a'.repeat(48) + '1' + privateKey).digest('hex')
  query.set('signature', sign(timestamp))
  const verifier = createLevelPlayVerifier({ privateKey, now: () => now })
  assert.equal(verifier.verify(query).issuedAt, Date.parse('2026-09-21T12:16:00Z'))
  assert.equal(verifier.verify(query).verifiedAt, now)
  query.set('signature', sign(String(Date.parse('2026-09-21T12:16:00Z'))))
  assert.throws(() => verifier.verify(query), /invalid_reward_signature/)
})

test('LevelPlay rejects invalid calendar dates and Unix timestamps without numeric fallback', () => {
  const now = Date.parse('2026-09-21T12:16:00Z'), privateKey = 'calendar-fixture-only-key'
  const verifier = createLevelPlayVerifier({ privateKey, now: () => now })
  for (const timestamp of ['202600211216', '202613211216', '202609001216', '202609321216',
    '202604311216', '202602291216', '202609212416', '202609211260', '20260921121',
    '2026092112160', '2026-09-211216', String(now), String(Math.floor(now / 1000))]) {
    const query = new URLSearchParams({ userId: 'a'.repeat(48), eventId: 'calendar-fixture', rewards: '1', timestamp })
    query.set('signature', createHash('md5').update(timestamp + 'calendar-fixture' + 'a'.repeat(48) + '1' + privateKey).digest('hex'))
    assert.throws(() => verifier.verify(query), /invalid_reward_callback/, timestamp)
  }
  const leapTimestamp = '202402291216'
  const leapQuery = new URLSearchParams({ userId: 'a'.repeat(48), eventId: 'calendar-fixture', rewards: '1', timestamp: leapTimestamp })
  leapQuery.set('signature', createHash('md5').update(leapTimestamp + 'calendar-fixture' + 'a'.repeat(48) + '1' + privateKey).digest('hex'))
  const leapNow = Date.parse('2024-02-29T12:16:47Z')
  assert.equal(createLevelPlayVerifier({ privateKey, now: () => leapNow }).verify(leapQuery).issuedAt,
    Date.parse('2024-02-29T12:16:00Z'))
})

test('LevelPlay calendar timestamps preserve nine-day retries and the five-minute future limit', () => {
  const privateKey = 'calendar-fixture-only-key', now = Date.parse('2026-09-21T12:16:00Z')
  const verifier = createLevelPlayVerifier({ privateKey, now: () => now })
  for (const [timestamp, accepted] of [['202609121216', true], ['202609121215', false],
    ['202609211221', true], ['202609211222', false]]) {
    const query = new URLSearchParams({ userId: 'a'.repeat(48), eventId: 'calendar-fixture', rewards: '1', timestamp })
    query.set('signature', createHash('md5').update(timestamp + 'calendar-fixture' + 'a'.repeat(48) + '1' + privateKey).digest('hex'))
    if (accepted) assert.equal(verifier.verify(query).amount, 1)
    else assert.throws(() => verifier.verify(query), /expired_reward_callback/, timestamp)
  }
})

test('LevelPlay accepts a six-character configured key but still rejects another key', () => {
  const privateKey = 'test01', now = Date.now()
  const query = new URLSearchParams({ userId: 'a'.repeat(48), eventId: 'short-key-test',
    rewards: '1', timestamp: new Date(now).toISOString().slice(0, 16).replace(/\D/g, '') })
  query.set('signature', createHash('md5').update(query.get('timestamp') + query.get('eventId') +
    query.get('userId') + query.get('rewards') + privateKey).digest('hex'))
  const reward = createLevelPlayVerifier({ privateKey, now: () => now }).verify(query)
  assert.equal(reward.amount, 1)
  assert.equal(reward.acknowledgement, 'short-key-test:OK')
  assert.throws(() => createLevelPlayVerifier({ privateKey: 'other1', now: () => now }).verify(query),
    /invalid_reward_signature/)
  query.set('rewards', '2')
  assert.throws(() => createLevelPlayVerifier({ privateKey, now: () => now }).verify(query),
    /invalid_reward_callback/)
})

test('LevelPlay fixed-width timestamp rejects signature boundary reinterpretation and retains the proof fingerprint', () => {
  const privateKey = 'test-only-levelplay-private-key', now = Date.now()
  const verify = createLevelPlayVerifier({ privateKey, now: () => now })
  const timestamp = new Date(now).toISOString().slice(0, 16).replace(/\D/g, '')
  const original = new URLSearchParams({ timestamp, eventId: '123abc', userId: 'a'.repeat(48), rewards: '1' })
  const signedPayload = timestamp + '123abc' + 'a'.repeat(48) + '1'
  const signature = createHash('md5').update(signedPayload + privateKey).digest('hex')
  original.set('signature', signature)
  const resegmented = new URLSearchParams(original)
  resegmented.set('timestamp', timestamp + '123')
  resegmented.set('eventId', 'abc')
  const first = verify.verify(original)
  assert.equal(first.eventId, '123abc')
  assert.throws(() => verify.verify(resegmented), /invalid_reward_callback/)
  assert.match(first.proofId, /^[a-f0-9]{64}$/)
  assert.equal(first.proofId, createHash('sha256').update(signedPayload).digest('hex'))
})
