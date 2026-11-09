// privateNetworkAddress: port of PrivateNetworkAddressDetector — same ranges,
// same fail-closed cases.

import { describe, expect, it } from 'vitest'
import { isPrivateOrReservedHost, isPrivateOrReservedUrl } from './privateNetworkAddress'

describe('isPrivateOrReservedHost', () => {
  // Revert-check: isPrivateOrReservedHost
  it('privateNetworkAddress_privateAndReservedIPv4_isBlocked', () => {
    for (const host of [
      '127.0.0.1',
      '127.255.255.254',
      '0.0.0.0',
      '0.1.2.3',
      '10.0.0.5',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.0.1',
      '169.254.169.254',
      '100.64.0.1',
      '224.0.0.1',
      '240.0.0.1',
      '255.255.255.255',
      '192.0.2.1',
      '198.18.0.1',
      '198.51.100.7',
      '203.0.113.9',
    ]) {
      expect(isPrivateOrReservedHost(host), host).toBe(true)
    }
  })

  it('privateNetworkAddress_publicIPv4_isAllowed', () => {
    for (const host of ['8.8.8.8', '1.1.1.1', '172.32.0.1', '172.15.255.255', '100.128.0.1']) {
      expect(isPrivateOrReservedHost(host), host).toBe(false)
    }
  })

  // Revert-check: ipv4FromAnyForm (legacy inet_aton forms)
  it('privateNetworkAddress_legacyIPv4Spellings_classifyLikeTheResolver', () => {
    expect(isPrivateOrReservedHost('0177.0.0.1')).toBe(true)
    expect(isPrivateOrReservedHost('0x7f000001')).toBe(true)
    expect(isPrivateOrReservedHost('0x7f.1')).toBe(true)
    expect(isPrivateOrReservedHost('2130706433')).toBe(true)
    expect(isPrivateOrReservedHost('127.1')).toBe(true)
    // Leading zero is octal to the resolver: 012 → 10 (private), 010 → 8 (public).
    expect(isPrivateOrReservedHost('012.0.0.1')).toBe(true)
    expect(isPrivateOrReservedHost('010.0.0.1')).toBe(false)
  })

  // Revert-check: isPrivateIPv6
  it('privateNetworkAddress_privateAndReservedIPv6_isBlocked', () => {
    for (const host of [
      '::1',
      '[::1]',
      '::',
      'fc00::1',
      'fd12:3456::1',
      'fe80::1',
      'ff02::1',
      '::ffff:10.0.0.1',
      '::ffff:7f00:1',
      '::10.0.0.1',
    ]) {
      expect(isPrivateOrReservedHost(host), host).toBe(true)
    }
  })

  it('privateNetworkAddress_publicIPv6_isAllowed', () => {
    expect(isPrivateOrReservedHost('2606:4700:4700::1111')).toBe(false)
    expect(isPrivateOrReservedHost('[2001:4860:4860::8888]')).toBe(false)
    expect(isPrivateOrReservedHost('::ffff:8.8.8.8')).toBe(false)
  })

  it('privateNetworkAddress_scopedIPv6Literal_failsClosed', () => {
    expect(isPrivateOrReservedHost('fe80::1%25en0')).toBe(true)
    expect(isPrivateOrReservedHost('2606:4700::1%en0')).toBe(true)
  })

  // Revert-check: RESERVED_HOSTNAMES / RESERVED_TLDS
  it('privateNetworkAddress_reservedNames_areBlocked', () => {
    for (const host of [
      'localhost',
      'LOCALHOST',
      'localhost.',
      'localhost.localdomain',
      'printer.local',
      'wiki.internal',
      'nas.lan',
      'git.corp',
      'router.home',
      'site.test',
      'host.invalid',
      'foo.example',
      'abc.onion',
      'intranet',
      'router',
    ]) {
      expect(isPrivateOrReservedHost(host), host).toBe(true)
    }
  })

  it('privateNetworkAddress_publicHostnames_areAllowed', () => {
    for (const host of [
      'example.com',
      'mail.google.com',
      'cdn.example.co.uk',
      'localhost.example.com',
    ]) {
      expect(isPrivateOrReservedHost(host), host).toBe(false)
    }
  })

  it('privateNetworkAddress_emptyHost_failsClosed', () => {
    expect(isPrivateOrReservedHost('')).toBe(true)
    expect(isPrivateOrReservedHost('[]')).toBe(true)
  })

  // Revert-check: the trailing-dot drop in isPrivateOrReservedHost
  it('privateNetworkAddress_trailingDot_classifiesLikeTheDotlessHost', () => {
    for (const host of [
      '192.168.0.1.',
      '127.0.0.1.',
      '169.254.169.254.',
      '127.1.',
      '2130706433.',
      '0x7f.1.',
      '0177.0.0.1.',
      'intranet.',
      'printer.',
      '[::1].',
    ]) {
      expect(isPrivateOrReservedHost(host), host).toBe(true)
    }
    for (const host of ['example.com.', 'mail.google.com.', '8.8.8.8.']) {
      expect(isPrivateOrReservedHost(host), host).toBe(false)
    }
  })

  // Revert-check: the empty-label refusal after the trailing-dot drop
  it('privateNetworkAddress_hostWithEmptyLabel_failsClosed', () => {
    for (const host of ['.', '192.168.0.1..', 'example.com..']) {
      expect(isPrivateOrReservedHost(host), host).toBe(true)
    }
  })

  it('privateNetworkAddress_url_classifiesByHostname', () => {
    expect(isPrivateOrReservedUrl(new URL('http://192.168.0.1/cgi-bin/reboot'))).toBe(true)
    expect(isPrivateOrReservedUrl(new URL('http://[::1]:8080/'))).toBe(true)
    // The WHATWG parser canonicalizes the legacy spelling before hostname is read.
    expect(isPrivateOrReservedUrl(new URL('http://0x7f.1/'))).toBe(true)
    expect(isPrivateOrReservedUrl(new URL('https://example.com/x'))).toBe(false)
  })

  // Revert-check: the trailing-dot drop in isPrivateOrReservedHost ("printer."
  // keeps its dot through the WHATWG parser; the IPv4 host loses it there).
  it('privateNetworkAddress_url_trailingDotHost_classifiesLikeTheDotlessHost', () => {
    expect(new URL('http://printer./').hostname).toBe('printer.')
    expect(isPrivateOrReservedUrl(new URL('http://printer./'))).toBe(true)
    expect(isPrivateOrReservedUrl(new URL('http://192.168.0.1./cgi-bin/reboot'))).toBe(true)
    expect(isPrivateOrReservedUrl(new URL('https://example.com./x'))).toBe(false)
  })
})
