'use strict'

function deletionMemberPath(memberId) {
  if (!/^[a-zA-Z0-9_-]{1,100}$/.test(memberId || '')) {
    throw Object.assign(new Error('invalid_member_id'), { code: 'invalid_member_id', status: 400 })
  }
  return `members/${memberId}`
}

// These storage-only helpers are shared by authenticated deletion and the
// scheduled job. Cleanup must not depend on Apple, advertising or AI keys.
async function purgeDeletedMemberData({ store, memberId }) {
  const path = deletionMemberPath(memberId)
  const marker = await store.get(path)
  if (!marker?.deletedAt) {
    throw Object.assign(new Error('member_not_deleted'), { code: 'member_not_deleted', status: 409 })
  }
  for (const collection of ['purchases', 'days', 'generations', 'generationResults', 'sessions', 'devices', 'challenges']) {
    while (true) {
      const rows = await store.list(`${path}/${collection}`, { limit: 20 })
      if (!rows.length) break
      for (const row of rows) await store.delete(row.path)
    }
  }
  while (true) {
    const rows = await store.list('notifications', { where: [{ field: 'memberId', op: '==', value: memberId }], limit: 100 })
    if (!rows.length) break
    for (const row of rows) await store.set(row.path, { appliedAt: row.data.appliedAt })
  }
  // Identity/purchase/reward anti-replay tombstones are deliberately unchanged.
}

async function deleteMemberAuthData({ store, memberId }) {
  deletionMemberPath(memberId)
  for (const collection of ['authSessions', 'authDevices', 'authChallenges', 'authRewardUsers']) {
    for (;;) {
      const rows = await store.list(collection, { where: [{ field: 'memberId', op: '==', value: memberId }], limit: 100 })
      if (!rows.length) break
      for (const { path } of rows) await store.runTransaction(async (tx) => {
        const current = await tx.get(path)
        // Reauthentication may bind a device to another member while cleanup
        // runs. Never remove the replacement owner's binding.
        if (current?.memberId === memberId) tx.delete(path)
      })
      if (rows.length < 100) break
    }
  }
  await store.delete(`authMemberRewards/${memberId}`)
}

function createStoreDeletionMaintenance({ store, clock = Date.now }) {
  const membership = { store, clock, memberPath: deletionMemberPath,
    purgeDeletedMember: (memberId) => purgeDeletedMemberData({ store, memberId }) }
  const auth = { deleteMemberAuth: (memberId) => deleteMemberAuthData({ store, memberId }) }
  return {
    cleanup: ({ limit = 100 } = {}) => cleanupDeletedMembers({ membership, auth, limit }),
    hasPending: async () => (await store.list('members', {
      where: [{ field: 'deletionCleanupState', op: '==', value: 'pending' }], limit: 1
    })).length > 0
  }
}

// A deletion tombstone is the durable outbox. Revocation happens in the same
// transaction as that marker; cleanup can be retried after a Cloud Run restart.
// Run from an IAM-protected maintenance job, never an unauthenticated client API.
async function completeMemberDeletion({ membership, auth, memberId }) {
  await membership.purgeDeletedMember(memberId)
  await auth.deleteMemberAuth(memberId)
  const path = membership.memberPath(memberId)
  await membership.store.runTransaction(async (tx) => {
    const marker = await tx.get(path)
    if (!marker?.deletedAt) throw new Error('member_not_deleted')
    tx.set(path, { id: memberId, deletedAt: marker.deletedAt, deletionCleanupState: 'complete',
      deletionCleanedAt: membership.clock() })
  })
}

async function cleanupDeletedMembers({ membership, auth, limit = 100 }) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error('invalid_cleanup_limit')
  const pending = await membership.store.list('members', {
    where: [{ field: 'deletionCleanupState', op: '==', value: 'pending' }], limit
  })
  let completed = 0, failed = 0
  for (const { id } of pending) {
    try { await completeMemberDeletion({ membership, auth, memberId: id }); completed++ } catch { failed++ }
  }
  return { examined: pending.length, completed, failed }
}

module.exports = { completeMemberDeletion, cleanupDeletedMembers, purgeDeletedMemberData,
  deleteMemberAuthData, createStoreDeletionMaintenance }
