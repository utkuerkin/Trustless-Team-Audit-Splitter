# Trustless Team Audit Splitter

Trustless Team Audit Splitter (TTAS) is a share-based wallet for distributing
web3 audit contest payouts. A team registers the wallet as its payout address,
and each member claims their allocation directly.

TTAS is intended for small, mutually identified audit teams. It removes the
need for one member to receive and manually redistribute team funds. Membership
and share changes use share-weighted voting.

## Project goals

- Distribute supported ERC20 payments without a custodial team account.
- Allow each member to claim independently.
- Preserve earnings accrued under an earlier share allocation.
- Support governed membership and share changes.
- Allow governance to retire a payment token without discarding existing claims.
- Allow a member to leave without requiring a team vote.
- Support up to 10 ERC20 payment tokens per wallet.

## Accounting model

Version 3 uses accumulator-based accounting:

```text
accPerShare[token]   cumulative tokens per share, scaled by 1e36
grossScaled(member)  = shares(member) * accPerShare[token]
accrued(member)      = (grossScaled(member) - rewardDebt(member, token)) / 1e36
newFunds             = balanceOf(wallet) + totalReleased - totalAccounted
```

`rewardDebt` is stored at accumulator precision. Subtraction occurs before the
final division, which prevents independent rounding operations across a share
change from creating liabilities greater than the wallet balance.

For standard, non-rebasing ERC20s, a share change first synchronizes every
active token and settles each current member at the old shares. If any active
token cannot be read, the complete share change reverts. This fail-closed rule
prevents an existing balance from being reassigned under a newer share table.

New members receive a reward-debt baseline at the current accumulator and
cannot claim funds accounted before they joined. Removed members retain their
settled `owed` balances.

Rounding is contract-favoring. A small amount of token base-unit dust can remain
after a share epoch changes.

## User operations

### Receive funds

Send a supported ERC20 to the wallet, or register the wallet as a contest payout
address. Funds are recognized lazily by `sync`, `claim`, or a share change.

### Claim funds

- `claim(token)` claims one active, quarantined, or retired token.
- `claimAll()` attempts to claim every active token in one transaction.

If one token rejects a transfer, the complete `claimAll()` transaction reverts.
Use `claim(token)` separately for the remaining tokens.

Quarantined and retired tokens are not included in `claimAll()`. Claim them
individually by address.

### Change members or shares

`proposeDistribution(members, shares)` proposes a complete replacement share
table. Shares must sum to 100,000. Adding a member, removing a member, and
changing allocations use the same proposal type.

Each member may have one live proposal. Up to 12 proposals can therefore be
active concurrently. Votes are weighted by current shares. A successful
distribution change cancels every other live proposal because their recorded
vote weights belong to the previous share table.

Execution fails if any active token cannot provide a valid balance. The share
table and proposal state remain unchanged. Remove or recover the affected token
before executing the distribution again.

### Add or remove a token

`proposeAddToken(token)` proposes another supported payment token. The same
share-weighted voting process applies. The token must provide a valid
`balanceOf` response when proposed and when added. The wallet supports a maximum
of 10 active tokens.

An existing balance at the newly added token address becomes distributable
after the token is added.

`proposeRemoveToken(token)` proposes permanent removal from the active token
set. Execution has two outcomes:

- A readable token is synchronized, current accrual is moved to `owed`, and the
  token becomes `RETIRED`.
- An unreadable token is removed from active use and becomes `QUARANTINED`.
  Current members and shares are frozen for that token.

Once a quarantined token becomes readable, anyone may call
`settleQuarantinedToken(token)`. Previously accounted claims are unchanged. Only
the unaccounted balance is allocated using the frozen shares. Settlement is
repeatable and the token remains `QUARANTINED`, so an early zero-value call
cannot strand a delayed payout.

Removal frees one active token slot. A quarantined or retired address cannot be
added again because its earlier accounting remains stored.
`getTokens()` returns active addresses only. Use `tokenState(token)` and emitted
events to inspect a known historical token.

### Leave

`leave()` settles the caller's accrued balances, removes the caller from the
member table, redistributes their shares proportionally among the remaining
members, and cancels live proposals whose vote weights are no longer valid.

The final member cannot leave because the wallet must retain a complete
100,000-share allocation. Leaving also fails if an active token is unreadable.
The team must recover or govern the removal of that token first.

## Governance model

The approval threshold is selected during wallet creation and cannot be
changed:

- `50,001` represents a simple majority.
- `100,000` requires unanimity.
- A threshold such as `66,667` provides a supermajority requirement.

A coalition holding the approval threshold can replace the complete member and
share table. Previously settled earnings remain claimable, but future income is
governed by the new table. Team selection and threshold configuration therefore
remain important trust assumptions.

An unanimity threshold can permanently block governance if a member loses
access to their key. A member can normally exit through `leave()`, but a broken
active token makes removal governance necessary before any share change or
exit. Use unanimity only when every key is expected to remain available.

## Token compatibility and limitations

TTAS is designed for standard, fixed-balance ERC20s such as USDC, USDT, DAI,
and WETH.

- Rebasing tokens are unsupported. A negative rebase can leave later claimants
  underfunded.
- Incoming fee-on-transfer tokens are accounted using the amount that reaches
  the wallet. A token that deducts an additional fee from the sender, beyond the
  requested transfer amount, is unsupported.
- A member blocked by a token issuer cannot receive that token until the issuer
  removes the block. Other members can still claim separately. If the wallet
  address itself is blocked, all claims for that token can fail.
- Native ETH is unsupported. Use WETH.
- ERC20 transfer callbacks and other nonstandard transfer behavior are
  unsupported.
- `balanceOf` must complete within a 100,000 gas stipend and return exactly one
  32-byte ABI word. Reverting, empty, short, or extra return data is treated as
  unavailable.
- Token addresses should still be reviewed before wallet creation or approval.

### Token quarantine and incomplete isolation

An unreadable active token cannot silently skip accounting. Operations that
depend on its current balance revert with `TokenUnavailable`, including `sync`,
`claim` for that token, `claimAll`, distribution execution, and `leave`.
Individual claims for other readable tokens still work.

Governance can remove the token while it is unreadable. Removal preserves
already-accounted claims and freezes the current shares for funds that could not
be measured. Share changes and `leave()` can continue after removal. Funds sent
while the token is quarantined are also assigned using the frozen shares on the
next settlement. Quarantine does not close after settlement, so later balances
remain recoverable under the same frozen table.
Already-accounted `owed` balances can still be claimed during quarantine if the
token's transfer function works.

Isolation remains incomplete in two important cases:

- Removal still requires the configured governance threshold. Unanimity with a
  lost key can therefore leave an unreadable token active indefinitely.
- Quarantine cannot repair the token itself. Claims remain unavailable if its
  transfer function is broken or the wallet is blocklisted.

Do not send funds to a token after it becomes `RETIRED`. Retired tokens are
permanently excluded from accounting, so later transfers to the wallet are
stranded. A quarantined token remains recoverable, but every later transfer uses
the shares frozen at removal.

## Delayed and overlapping payouts

Direct ERC20 transfers do not include a contest identifier or payment epoch.
TTAS allocates a readable payment using the share table in effect when it is
recognized. Distribution changes synchronize all active balances first, but a
payment arriving after a completed change uses the newer table even if it
belongs to an older contest.

Use a separate wallet clone for each contest or payout agreement when payout
timing can overlap. If one wallet is reused, do not change its shares until all
payments expected under the earlier allocation have arrived and been
synchronized.

## Repository layout

| Path | Description |
| --- | --- |
| `src/v3/TTASv3.sol` | Current accumulator accounting and governance contract |
| `src/v3/TTASFactoryV3.sol` | Ownerless EIP-1167 clone factory with an immutable implementation |
| `src/interfaces/ITTASv3.sol` | Wallet initialization interface |
| `src/v1/` and `src/TTASFactory.sol` | Legacy version 1 contracts |
| `script/DeployV3.s.sol` | Deployment script for the implementation and factory |
| `script/CreateWallet.s.sol` | Wallet creation script |
| `test/v3/` | Version 3 unit, fuzz, regression, and gas tests |

Version 1 used a fixed-share push distribution. The abandoned version 2
development branch used per-payment snapshots. Version 3 replaces that design
with accumulator accounting and pull-based claims.

## Development

```bash
forge build
forge test
```

The Foundry profile pins Solidity 0.8.34, the Paris EVM target, and 200-run
optimization so deployment and verification use the same bytecode settings.

## Deployment

Deploy the version 3 implementation and factory:

```bash
forge script script/DeployV3.s.sol \
  --rpc-url $RPC_URL --account <keystore-account> --broadcast --verify
```

Configure and create a wallet:

```bash
export FACTORY=0x...
export MEMBERS=0xAlice,0xBob
export SHARES=60000,40000
export TOKENS=0xUSDC,0xWETH
export THRESHOLD=66667

forge script script/CreateWallet.s.sol \
  --rpc-url $RPC_URL --account <keystore-account> --broadcast
```

Register the resulting wallet address with the relevant payout provider.

## Security and testing

The version 3 suite includes unit tests, accounting regressions, fuzz tests,
governance lifecycle tests, token quarantine tests, malformed-return tests, and
a maximum-member and maximum-token gas test. The standard ERC20 accounting
model has also been checked against a stateful reference model.

The repository has not received a formal third-party audit. It should be
treated as pre-release software until an independent review is completed.

## Contributing

Contributions are welcome through GitHub pull requests. Major behavioral
changes should be discussed in an issue and include appropriate tests.

## Support

EVM address:

```text
0x526C34d58f50Bc2b610352f211841caDB7b20caA
```

## License

This project is available under the MIT License. See [LICENSE](LICENSE).

## Attribution

```solidity
// Derived from trustless-team-audit-splitter.
// Original work by ljjeth: https://github.com/utkuerkin/trustless-team-audit-splitter
```

## Contact

- GitHub: [@utkuerkin](https://github.com/utkuerkin)
- X: [@ljjeth](https://x.com/ljjeth)
- Telegram: `@utkuerkin`
