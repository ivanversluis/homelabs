'use strict';

function publicIPv4(value) {
  if (typeof value !== 'string') throw new Error('Expected an IPv4 address');
  const ip = value.trim();
  const parts = ip.split('.');
  if (parts.length !== 4 || parts.some(p => !/^(0|[1-9][0-9]{0,2})$/.test(p) || Number(p) > 255)) {
    throw new Error('Invalid IPv4 address');
  }
  const [a, b, c] = parts.map(Number);
  if (a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 192 && b === 0 && (c === 0 || c === 2)) ||
      (a === 192 && b === 88 && c === 99) ||
      (a === 198 && (b === 18 || b === 19)) ||
      (a === 198 && b === 51 && c === 100) || (a === 203 && b === 0 && c === 113)) {
    throw new Error('Address is not an eligible public IPv4 address');
  }
  return ip;
}

function validateConfig(config) {
  if (!/^[a-f0-9]{32}$/i.test(config.account_id || '') ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(config.group_id || '') ||
      config.group_name !== 'homelab-dynamic-home-ip' || typeof config.dry_run !== 'boolean') {
    throw new Error('Set account/group IDs and a boolean dry_run for the dedicated home IP group');
  }
  return config;
}

function groupIP(envelope, config) {
  validateConfig(config);
  const group = envelope?.result;
  if (envelope?.success !== true || group?.id !== config.group_id || group?.name !== config.group_name ||
      group?.is_default === true || !Array.isArray(group?.include) || group.include.length !== 1 ||
      Object.keys(group.include[0]).length !== 1 || !group.include[0].ip ||
      Object.keys(group.include[0].ip).length !== 1 ||
      !Array.isArray(group.exclude) || group.exclude.length !== 0 ||
      !Array.isArray(group.require) || group.require.length !== 0) {
    throw new Error('Group identity or selectors differ from the dedicated one-IP group; no write permitted');
  }
  const cidr = group.include[0].ip.ip;
  if (typeof cidr !== 'string' || !cidr.endsWith('/32')) throw new Error('Expected exactly one IPv4 /32 rule');
  return publicIPv4(cidr.slice(0, -3));
}

function prepare(config, ipA, ipB, envelope) {
  const first = publicIPv4(ipA);
  const second = publicIPv4(ipB);
  if (first !== second) throw new Error('Public IP sources disagree; no write permitted');
  const old = groupIP(envelope, config);
  const changed = old !== first;
  return {
    changed,
    should_update: changed && !config.dry_run,
    dry_run: config.dry_run,
    expected_ip: first,
    payload: {name: config.group_name, include: [{ip: {ip: `${first}/32`}}], exclude: [], require: []},
  };
}

function verify(config, proposed, envelope) {
  if (groupIP(envelope, config) !== proposed.expected_ip) throw new Error('Cloudflare read-back verification failed');
  return {updated: true, verified: true};
}

if (typeof module !== 'undefined') module.exports = {publicIPv4, validateConfig, groupIP, prepare, verify};
