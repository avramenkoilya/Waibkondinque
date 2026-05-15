const { chromium } = require('@playwright/test');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function getEncryptionKey() {
  const localStatePath = path.join(process.env.LOCALAPPDATA, 'Google', 'Chrome', 'User Data', 'Local State');
  const localState = JSON.parse(fs.readFileSync(localStatePath, 'utf8'));
  const encryptedKeyB64 = localState.os_crypt.encrypted_key;
  const encryptedKey = Buffer.from(encryptedKeyB64, 'base64').slice(5); // strip DPAPI prefix

  // Write PS script to temp file to avoid inline quoting issues
  const psScript = path.join(process.env.TEMP, 'dpapi_decrypt.ps1');
  fs.writeFileSync(psScript, [
    `Add-Type -AssemblyName System.Security`,
    `$enc = [System.Convert]::FromBase64String('${encryptedKey.toString('base64')}')`,
    `$dec = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'CurrentUser')`,
    `[System.Convert]::ToBase64String($dec)`,
  ].join('\r\n'));

  const result = execSync(`powershell -ExecutionPolicy Bypass -File "${psScript}"`, { encoding: 'utf8' }).trim();
  fs.unlinkSync(psScript);
  return Buffer.from(result, 'base64');
}

function decryptCookie(encryptedValue, key) {
  // v10 format: 3 bytes version + 12 bytes nonce + ciphertext + 16 bytes tag
  const buf = Buffer.from(encryptedValue);
  if (buf.slice(0, 3).toString() !== 'v10') return null;
  const nonce = buf.slice(3, 15);
  const ciphertext = buf.slice(15, buf.length - 16);
  const tag = buf.slice(buf.length - 16);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAuthTag(tag);
  return decipher.update(ciphertext) + decipher.final();
}

async function main() {
  const key = getEncryptionKey();

  // Chrome exclusively locks Cookies — copy via .NET with FileShare.ReadWrite
  const cookiesPath = path.join(process.env.LOCALAPPDATA, 'Google', 'Chrome', 'User Data', 'Default', 'Network', 'Cookies');
  const tmpPath = path.join(process.env.TEMP, 'chrome_cookies_tmp.db');

  const psScript = path.join(process.env.TEMP, 'copy_cookies.ps1');
  fs.writeFileSync(psScript, [
    `$src = [System.IO.File]::Open('${cookiesPath.replace(/\\/g, '\\\\')}', 'Open', 'Read', 'ReadWrite')`,
    `$dst = [System.IO.File]::Create('${tmpPath.replace(/\\/g, '\\\\')}')`,
    `$src.CopyTo($dst)`,
    `$dst.Close(); $src.Close()`,
  ].join('\r\n'));
  execSync(`powershell -ExecutionPolicy Bypass -File "${psScript}"`, { stdio: 'inherit' });
  fs.unlinkSync(psScript);

  const Database = require('better-sqlite3');
  const db = new Database(tmpPath, { readonly: true });
  const rows = db.prepare(`SELECT name, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite
    FROM cookies WHERE host_key LIKE '%github.com%'`).all();
  db.close();

  const cookies = rows.map(row => {
    const decrypted = decryptCookie(row.encrypted_value, key);
    if (!decrypted) return null;
    return {
      name: row.name,
      value: decrypted,
      domain: '.github.com',
      path: row.path || '/',
      secure: !!row.is_secure,
      httpOnly: !!row.is_httponly,
      sameSite: row.samesite === 2 ? 'Strict' : row.samesite === 1 ? 'Lax' : 'None',
    };
  }).filter(Boolean);

  console.log(`Loaded ${cookies.length} GitHub cookies`);

  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  await context.addCookies(cookies);

  const page = await context.newPage();
  await page.goto('https://github.com/settings/tokens');
  await page.waitForLoadState('networkidle');
  console.log('Page title:', await page.title());

  const tokenRow = page.locator('li').filter({ hasText: 'ClaudeCode' });
  await tokenRow.waitFor({ timeout: 10000 });
  console.log('Found ClaudeCode token');

  await tokenRow.locator('button', { hasText: 'Delete' }).click();

  const confirmBtn = page.locator('button', { hasText: /I understand, delete this token/i });
  await confirmBtn.waitFor({ timeout: 5000 });
  await confirmBtn.click();

  await page.waitForTimeout(2000);
  console.log('Token deleted!');
  await browser.close();
  fs.unlinkSync(tmpPath);
}

main().catch(console.error);
