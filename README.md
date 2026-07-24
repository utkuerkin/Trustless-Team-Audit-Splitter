# Trustless Team Audit Splitter (TTAS)

A trustless, share-based team wallet for audit contest payouts. Register the wallet
address as your team's payout address; earnings accrue to members pro-rata and are
claimed pull-style. Membership and share changes go through share-weighted voting —
and **money earned under the old share table is always settled at the old shares
first**, so a member who joins later can never touch earlier payouts, and a member
who leaves keeps everything they earned.

## Why

Team audits have a trust problem: someone's EOA receives the payout and everyone
else hopes they split it fairly. TTAS replaces that person with a contract:

- 🔒 **Trustless distribution** — nobody custodies the funds; every member claims
  their own share directly.
- 📈 **Shares** — a beginner can join at a lower percentage; the table is changed
  by vote, with the approval threshold your team chooses (majority → unanimity).
- 📸 **Automatic snapshots** — any share change first settles everyone's accrued
  earnings, so past money is locked to past shares. Joiners take nothing
  retroactively; leavers lose nothing they earned.
- 🚪 **Unilateral exit** — `leave()` lets any member walk away without permission,
  with their earnings intact. Nobody can be trapped.
- 💰 **Multi-token** — up to 10 ERC20 payment tokens per wallet, extensible by vote.

## How it works (v3)

v3 uses MasterChef-style accumulator accounting instead of per-payment snapshots:

```
accPerShare[token]   cumulative tokens-per-share (scaled by 1e36)
grossScaled(member)  = shares(member) * accPerShare
accrued(member)      = (grossScaled(member) - rewardDebt(member)) / 1e36
new funds            = balanceOf(this) + totalReleased - totalAccounted
```

`rewardDebt` is stored at accumulator precision. Subtraction happens before the
single final division, so rounding at a share-table boundary cannot create more
claimable tokens than the wallet owns.

- **Receiving**: just send ERC20s to the wallet (or register it as the contest
  payout address). No action needed — funds are picked up lazily by `sync`.
- **Claiming**: `claim(token)` / `claimAll()` — O(1), pull-based, per member.
  One member being blocklisted by a token can never freeze the others.
- **Changing the team**: `proposeDistribution(members, shares)` proposes a complete
  new share table (sum = 100 000). Adding, removing, and re-weighting members are
  all the same operation — anyone omitted is removed. Proposals are validated at
  creation, voted share-weighted, live for 7 days, and executed by anyone once the
  threshold is reached. Each member may have one live proposal, so up to 12 can
  proceed concurrently without one minority member monopolizing a global slot.
  Executing a distribution cancels every other live proposal because its recorded
  vote weights belong to the old share table.
- **Adding a token**: `proposeAddToken(token)` — same voting flow. Also rescues
  funds a contest already paid in an unlisted token. Duplicate concurrent token
  proposals, and proposals left over when the 10-token cap is reached, are
  cancelled automatically.
- **Leaving**: `leave()` settles your earnings, redistributes your shares pro-rata
  to the rest, and cancels every live proposal (their vote weights went stale).

### Trust model — read before using

TTAS is a *trust-minimizing* tool for small teams, not a fully adversarial DAO:

- **Earned money is safe, future money is social.** Settled earnings (`owed`) are
  claimable forever, even after removal. But a coalition holding the approval
  threshold can rewrite the share table for future income. Your guaranteed
  protections are: past earnings + `leave()`.
- **Pick the threshold carefully** (set at wallet creation, immutable):
  `50_001` = simple majority — most agile, but a majority holder rules the table.
  `100_000` = unanimity — nobody's share changes without consent, but one lost key
  deadlocks governance forever. A supermajority (e.g. `66_667`) is a sane default.
- **Tokens**: designed for standard ERC20s (USDC, WETH, ...). Rebasing tokens are
  unsupported. An ordinary `balanceOf` revert from a whitelisted token is caught,
  but isolation is not absolute: a hostile token can consume nearly all forwarded
  gas or return arithmetic-extreme values and still block operations that sync
  every token. Only whitelist vetted tokens. Native ETH is not supported — use
  WETH.

### Delayed and overlapping contest payouts

Direct ERC20 transfers do not include a contest ID or payment epoch. TTAS must
therefore split each payment using the share table in force **when the tokens
arrive**, even if the payment belongs to an older contest.

If Contest A may pay after the team has already adopted Contest B's split, use a
fresh wallet clone for each contest or payout agreement. Clones are cheap, and
separate addresses preserve the intended attribution without relying on payment
timing. If one wallet is reused, do not change its shares until every earlier
payment expected at that address has arrived.

## Repository layout

| Path | What |
|---|---|
| `src/v3/TTASv3.sol` | **Current** wallet: accumulator accounting + governance |
| `src/v3/TTASFactoryV3.sol` | Ownerless EIP-1167 clone factory (immutable implementation) |
| `src/interfaces/ITTASv3.sol` | Initialization interface |
| `src/v1/`, `src/TTASFactory.sol` | v1: minimal fixed-share push splitter (legacy) |
| `script/DeployV3.s.sol` | Deploys implementation + factory |
| `script/CreateWallet.s.sol` | Creates a team wallet via env config |
| `test/v3/` | Accounting, governance, regression, fuzz, and gas-stress tests |

Version history: **v1** shipped as a static push-splitter (no governance, no
snapshots). **v2-dev** (branch) attempted per-payment snapshots + voting but had
fatal accounting flaws and was abandoned. **v3** is the rewrite: same goals,
accumulator accounting, hardened governance.

## Development

```bash
forge build
forge test
```

## Deployment

Deploy the implementation + factory (one-shot; the factory has no owner):

```bash
forge script script/DeployV3.s.sol \
  --rpc-url $RPC_URL --account <keystore-account> --broadcast --verify
```

Create your team's wallet:

```bash
export FACTORY=0x...                 # from the step above
export MEMBERS=0xAlice,0xBob         # 1..12 unique addresses
export SHARES=60000,40000            # sum must be exactly 100000
export TOKENS=0xUSDC,0xWETH          # 1..10 payment tokens
export THRESHOLD=66667               # 50001 (majority) .. 100000 (unanimity)

forge script script/CreateWallet.s.sol \
  --rpc-url $RPC_URL --account <keystore-account> --broadcast
```

Then register the printed wallet address as your team's payout address.

## Security

v3 was reviewed with a multi-agent adversarial audit (independent reviewers per
attack surface — accounting, governance, token/DoS, lifecycle — each finding
verified by a skeptical second pass). All confirmed issues were fixed or are
documented in the contract natspec as explicit design tradeoffs. Highlights:

- Ordinary reverting `balanceOf` calls are caught so a paused/broken token does
  not automatically brick governance or exits. Gas-griefing and
  arithmetic-extreme tokens remain explicitly unsupported.
- Scaled reward debt performs subtraction before flooring, so share changes
  cannot manufacture token-unit liabilities; rounding dust stays in the wallet.
- Clones cannot be front-run initialized; `leave()` can never produce a
  zero-share member; the wallet itself cannot be assigned membership; concurrent
  proposals are bounded to one per member; PASSED/DEFEATED states are mutually
  exclusive.

This project is provided as is. It has **not** had a formal third-party audit —
perform your own due diligence before trusting it with meaningful funds.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major
changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## Support

If you find this project useful, consider supporting its development:

EVM Address: 0x526C34d58f50Bc2b610352f211841caDB7b20caA

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Attribution

If you use this code in your project, please provide attribution:
```solidity
// This code is derived from trustless-team-audit-splitter
// Original work by ljjeth (https://github.com/utkuerkin/trustless-team-audit-splitter)
```

## Contact

- GitHub: [@utkuerkin](https://github.com/utkuerkin)
- Twitter/X: [@ljjeth](https://x.com/ljjeth)
- Telegram: @utkuerkin
