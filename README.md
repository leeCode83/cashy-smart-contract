# Cashy Smart Contract

Kontrak inti Cashy — advance penghasilan AdSense yang sudah final, pool tiga
lapis, dan registri anti-didanai-ganda. Latar lengkap: `cashy-web/docs/42-cashy.md`.

## Kontrak

| Kontrak | Tanggung jawab |
|---|---|
| `MockIDRX` | Stablecoin demo, 2 desimal (1 unit = 1 sen). Mint admin-gated. |
| `PayoutNullifierRegistry` | Satu payout = satu advance, bisa dibaca lender mana pun. |
| `TrancheVault` | ERC-4626 per lapis (Senior/Junior/Reserve), kapasitas, alur deploy/repay. |
| `CashyAdvance` | attest (bureau) → requestAdvance → settle/markDefaulted + rapor kredit. |
| `WaterfallSweep` | Principal 100% kembali ke Senior; fee 70/20/10 jadi yield LP. |

## Alur dana

```
LP ──deposit──▶ TrancheVault (Senior/Junior/Reserve, ERC-4626)
Kreator ──requestAdvance(amount, payoutId)──▶ CashyAdvance
   ├─ nullifier.claim(payoutId)      // anti didanai dua kali
   └─ seniorVault.deploy(creator)    // uang cair hari ini
Tanggal 21 (warp): payout Google mendarat (DemoKeeper mint IDRX)
Keeper ──settle(id)──▶ transferFrom kreator (principal + fee)
   └─ sweep.distribute: principal → Senior, fee 70/20/10 → 3 vault
      (fee masuk tanpa mint share → harga share naik = yield LP)
   └─ onTimeRepays[creator]++       // rapor kredit onchain
```

Bureau AI tetap offchain; kontrak hanya menyimpan vonisnya (`attest`:
finalBalance, maxBps, payoutDate) dari `ATTESTER_ROLE`.

## Menjalankan demo

```bash
forge build
forge test                 # unit tests + 3 invariant
anvil                      # terminal terpisah
forge script script/Deploy.s.sol --rpc-url http://localhost:8544 --broadcast
# buat advance (attest + requestAdvance) dari UI/script Anda
# warp ke tanggal 21 lalu jalankan keeper:
forge script script/DemoKeeper.s.sol --rpc-url http://localhost:8544 --broadcast \
  # dengan env: ADVANCE_ADDRESS, IDRX_ADDRESS, CREATOR_ADDRESS
```

`Deploy.s.sol` memakai private key default Anvil #0; override via
`KEEPER_PRIVATE_KEY`.

## Keamanan

- Solidity ^0.8.30, custom errors, checks-effects-interactions.
- OpenZeppelin v5: `ERC4626`, `AccessControl`. Tidak ada proxy — immutable.
- Invariant (fuzz 256×500): solvensi pool (aset 3 vault = deposit LP + fee −
  principal di luar), akuntansi vault, klaim nullifier final.

## Batasan desain (hackathon ceiling)

- `ponytail:` defaulted advance tetap di buku Senior; tidak ada loss-absorption
  Junior-first di kode (UI menampilkan urutan risikonya secara statis).
- `ponytail:` fee split rasio tetap (70/20/10), bukan target-yield per lapis;
  upgrade path: waterfall berbasis target.
- Keeper sentralis (`SETTLER_ROLE`) — produksi mengganti dengan rail debit
  open finance berlisensi BI.
- `MockIDRX` mock — jangan pernah ke mainnet.
