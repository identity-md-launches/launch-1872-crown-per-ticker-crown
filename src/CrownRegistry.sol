// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICrownRegistry} from "./interfaces/ICrownRegistry.sol";

/// @title CrownRegistry
/// @notice One canonical token per ticker: the king. Anyone can challenge a king with a bonded ETH
/// stake-vote; if the challenger side out-stakes the king side within the window and quorum is met,
/// the crown flips after a timelock. Resolution is purely rule-based: there is no admin.
///
/// Money flow of a resolved challenge (all pull-pattern, see `claim` / `withdrawTreasury`):
/// - winning side: every stake fully refundable, plus a pro-rata share of half the slash;
/// - losing side: 80% of every stake refundable, 20% slashed;
/// - slash: half to the winning-side stakers pro-rata, half to `TREASURY`.
/// The challenger's bond is the challenger's opening stake on the challenger side.
///
/// Displacement: a live challenge still in its staking window can be displaced by a new challenger
/// bonding exactly twice its bond. The displaced challenge ends at once with every stake on both
/// sides fully refundable (nothing slashed, no cooldown, no crown change) and the new challenge
/// starts its own window. The challenge slot is therefore never a lock: a king, or an ally, who
/// opens a sham challenge against itself to keep outsiders out can be displaced for 0.02 ETH, and
/// each further round doubles the bond at stake, which a sham cannot sustain for free.
contract CrownRegistry is ICrownRegistry {
    // ---------------------------------------------------------------- parameters

    uint256 public constant BOND = 0.01 ether;
    uint256 public constant QUORUM = 0.05 ether;
    uint64 public constant MIN_REIGN = 7 days;
    uint64 public constant STAKE_WINDOW = 72 hours;
    uint64 public constant TIMELOCK = 24 hours;
    uint64 public constant COOLDOWN = 3 days;
    /// @dev Share of the losing side that is slashed, in basis points; the rest is refundable.
    uint256 public constant SLASH_BPS = 2_000;
    uint256 public constant BPS = 10_000;
    address public constant TREASURY = 0xf19F11Dee16a341671E6Ed3e209b704C1Bbc3E57;

    // ---------------------------------------------------------------- types

    enum Side {
        King,
        Challenger
    }

    struct Challenge {
        bytes32 ticker;
        address challengerToken;
        address challengerBeneficiary;
        uint64 openedAt;
        uint64 windowEnd;
        uint64 finalizeAfter;
        bool finalized;
        bool challengerWon;
        uint256 kingStake;
        uint256 challengerStake;
        /// @dev Half of the slash, split pro-rata among winning-side stakers (fixed at finalize).
        uint256 winnerBonus;
        /// @dev The opening bond: `BOND`, or twice the bond of the challenge this one displaced.
        uint256 bond;
        /// @dev The challenge that displaced this one, or 0. A displaced challenge is finalized at
        /// once with full refunds on both sides.
        uint256 displacedBy;
    }

    struct TickerTotals {
        uint256 challengesOpened;
        uint256 dethronements;
        uint256 kingStakedEver;
        uint256 challengerStakedEver;
    }

    // ---------------------------------------------------------------- state

    mapping(bytes32 ticker => King) internal _kings;
    mapping(bytes32 ticker => uint256 challengeId) public liveChallenge;
    mapping(bytes32 ticker => uint64) public cooldownUntil;
    mapping(bytes32 ticker => TickerTotals) public tickerTotals;

    uint256 public challengeCount;
    mapping(uint256 challengeId => Challenge) internal _challenges;
    mapping(uint256 challengeId => mapping(address staker => uint256)) public kingStakeOf;
    mapping(uint256 challengeId => mapping(address staker => uint256)) public challengerStakeOf;
    mapping(uint256 challengeId => mapping(address staker => bool)) public claimed;

    /// @notice ETH owed to `TREASURY`, withdrawable by anyone through `withdrawTreasury`.
    uint256 public treasuryOwed;

    // ---------------------------------------------------------------- events

    event Crowned(bytes32 indexed ticker, address indexed token, address indexed beneficiary, uint64 reignStartedAt);
    event ChallengeOpened(
        uint256 indexed challengeId,
        bytes32 indexed ticker,
        address indexed challengerToken,
        address challenger,
        uint64 windowEnd,
        uint64 finalizeAfter
    );
    event Staked(uint256 indexed challengeId, address indexed staker, Side side, uint256 amount);
    event ChallengeDisplaced(
        uint256 indexed challengeId, uint256 indexed byChallengeId, bytes32 indexed ticker, uint256 bond
    );
    event Dethroned(
        uint256 indexed challengeId,
        bytes32 indexed ticker,
        address indexed newKing,
        address oldKing,
        uint256 kingStake,
        uint256 challengerStake
    );
    event ChallengeFailed(
        uint256 indexed challengeId, bytes32 indexed ticker, uint256 kingStake, uint256 challengerStake
    );
    event Claimed(uint256 indexed challengeId, address indexed staker, uint256 amount);
    event TreasuryWithdrawn(uint256 amount);

    // ---------------------------------------------------------------- errors

    error ZeroTicker();
    error ZeroAddress();
    error AlreadyCrowned(bytes32 ticker);
    error NotCrowned(bytes32 ticker);
    error WrongBond(uint256 sent, uint256 required);
    error ChallengeLive(bytes32 ticker, uint256 challengeId);
    error ReignTooYoung(uint64 challengeableAt);
    error InCooldown(uint64 cooldownEnds);
    error SameToken();
    error UnknownChallenge(uint256 challengeId);
    error ZeroStake();
    error WindowClosed(uint64 windowEnd);
    error TooEarly(uint64 finalizeAfter);
    error AlreadyFinalized(uint256 challengeId);
    error NotFinalized(uint256 challengeId);
    error NothingToClaim();
    error TransferFailed();

    // ---------------------------------------------------------------- constructor

    /// @param genesisSymbol Symbol of the ticker crowned at deployment (upper-cased here), or "" for none.
    /// @param genesisToken The genesis king's token, or address(0) for no genesis crown.
    /// @param genesisBeneficiary The genesis king's fee recipient, or address(0) for no genesis crown.
    constructor(string memory genesisSymbol, address genesisToken, address genesisBeneficiary) {
        if (genesisToken == address(0) && genesisBeneficiary == address(0) && bytes(genesisSymbol).length == 0) {
            return;
        }
        _crown(tickerOf(genesisSymbol), genesisToken, genesisBeneficiary);
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc ICrownRegistry
    function king(bytes32 ticker) public view returns (King memory) {
        return _kings[ticker];
    }

    function challenges(uint256 challengeId) external view returns (Challenge memory) {
        return _challenges[challengeId];
    }

    /// @notice keccak256 of the upper-cased ASCII symbol: the canonical ticker id.
    function tickerOf(string memory symbol) public pure returns (bytes32) {
        bytes memory s = bytes(symbol);
        for (uint256 i = 0; i < s.length; i++) {
            if (s[i] >= 0x61 && s[i] <= 0x7a) s[i] = bytes1(uint8(s[i]) - 32);
        }
        return keccak256(s);
    }

    /// @notice Whether `ticker` has a live (not yet finalized) challenge.
    function hasLiveChallenge(bytes32 ticker) public view returns (bool) {
        uint256 id = liveChallenge[ticker];
        return id != 0 && !_challenges[id].finalized;
    }

    /// @notice The bond `openChallenge(ticker, ...)` must send now: `BOND`, or twice the live
    /// challenge's bond while that challenge is still in its staking window. Zero while a live
    /// challenge is past its window (nothing can be opened until it is finalized).
    function requiredBond(bytes32 ticker) public view returns (uint256) {
        uint256 id = liveChallenge[ticker];
        if (id == 0 || _challenges[id].finalized) return BOND;
        Challenge storage live = _challenges[id];
        return block.timestamp < live.windowEnd ? live.bond * 2 : 0;
    }

    /// @notice What `staker` can still pull out of a finalized challenge.
    function claimable(uint256 challengeId, address staker) public view returns (uint256 amount) {
        Challenge storage c = _challenges[challengeId];
        if (!c.finalized || claimed[challengeId][staker]) return 0;
        uint256 kingPart = kingStakeOf[challengeId][staker];
        uint256 chalPart = challengerStakeOf[challengeId][staker];
        // A displaced challenge refunds both sides in full.
        if (c.displacedBy != 0) return kingPart + chalPart;
        (uint256 winStake, uint256 winTotal, uint256 loseStake) =
            c.challengerWon ? (chalPart, c.challengerStake, kingPart) : (kingPart, c.kingStake, chalPart);
        if (winStake != 0) amount += winStake + (c.winnerBonus * winStake) / winTotal;
        // Floored per staker, so the refunds never sum to more than the side's unslashed 80%.
        if (loseStake != 0) amount += (loseStake * (BPS - SLASH_BPS)) / BPS;
    }

    // ---------------------------------------------------------------- actions

    /// @notice The first registration for a ticker crowns `token`. Later ones revert.
    function registerKing(bytes32 ticker, address token, address beneficiary) external {
        if (_kings[ticker].token != address(0)) revert AlreadyCrowned(ticker);
        _crown(ticker, token, beneficiary);
    }

    /// @notice Open a challenge against the king of `ticker` with an opening stake of `requiredBond(ticker)`:
    /// `BOND`, or exactly twice the live challenge's bond to displace it while it is still in its
    /// staking window (see `ChallengeDisplaced`). The caller becomes the beneficiary of
    /// `challengerToken` if the challenge succeeds.
    function openChallenge(bytes32 ticker, address challengerToken) external payable returns (uint256 challengeId) {
        King storage k = _kings[ticker];
        if (k.token == address(0)) revert NotCrowned(ticker);
        if (challengerToken == address(0)) revert ZeroAddress();
        if (challengerToken == k.token) revert SameToken();
        uint256 required = BOND;
        uint256 displaced = liveChallenge[ticker];
        if (displaced != 0 && !_challenges[displaced].finalized) {
            // Past its window the live challenge is being decided: nothing can displace it.
            if (block.timestamp >= _challenges[displaced].windowEnd) revert ChallengeLive(ticker, displaced);
            required = _challenges[displaced].bond * 2;
        } else {
            displaced = 0;
        }
        if (msg.value != required) revert WrongBond(msg.value, required);
        uint64 challengeableAt = k.reignStartedAt + MIN_REIGN;
        if (block.timestamp < challengeableAt) revert ReignTooYoung(challengeableAt);
        if (block.timestamp < cooldownUntil[ticker]) revert InCooldown(cooldownUntil[ticker]);

        challengeId = ++challengeCount;
        uint64 windowEnd = uint64(block.timestamp) + STAKE_WINDOW;
        Challenge storage c = _challenges[challengeId];
        c.ticker = ticker;
        c.challengerToken = challengerToken;
        c.challengerBeneficiary = msg.sender;
        c.openedAt = uint64(block.timestamp);
        c.windowEnd = windowEnd;
        c.finalizeAfter = windowEnd + TIMELOCK;
        c.bond = msg.value;
        liveChallenge[ticker] = challengeId;
        tickerTotals[ticker].challengesOpened += 1;

        if (displaced != 0) {
            // Ends at once: both sides fully refundable through `claim`, no slash, no cooldown.
            Challenge storage old = _challenges[displaced];
            old.finalized = true;
            old.displacedBy = challengeId;
            emit ChallengeDisplaced(displaced, challengeId, ticker, msg.value);
        }
        emit ChallengeOpened(challengeId, ticker, challengerToken, msg.sender, windowEnd, c.finalizeAfter);
        _stake(challengeId, c, Side.Challenger, msg.value);
    }

    /// @notice Stake ETH on `side` of a live challenge during its window.
    function stake(uint256 challengeId, Side side) external payable {
        Challenge storage c = _challenges[challengeId];
        if (c.openedAt == 0) revert UnknownChallenge(challengeId);
        if (msg.value == 0) revert ZeroStake();
        if (block.timestamp >= c.windowEnd) revert WindowClosed(c.windowEnd);
        if (c.finalized) revert AlreadyFinalized(challengeId); // displaced inside its window
        _stake(challengeId, c, side, msg.value);
    }

    /// @notice Resolve a challenge once its window and timelock have both passed. Anyone may call.
    function finalize(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        if (c.openedAt == 0) revert UnknownChallenge(challengeId);
        if (c.finalized) revert AlreadyFinalized(challengeId);
        if (block.timestamp < c.finalizeAfter) revert TooEarly(c.finalizeAfter);

        bool challengerWon = c.challengerStake > c.kingStake && c.kingStake + c.challengerStake >= QUORUM;
        (uint256 losingTotal, uint256 winningTotal) =
            challengerWon ? (c.kingStake, c.challengerStake) : (c.challengerStake, c.kingStake);

        uint256 slash = (losingTotal * SLASH_BPS) / BPS;
        uint256 toWinners = slash / 2;
        uint256 toTreasury = slash - toWinners;
        if (winningTotal == 0) {
            // Nobody to share with: the whole slash goes to the treasury.
            toTreasury += toWinners;
            toWinners = 0;
        }

        c.finalized = true;
        c.challengerWon = challengerWon;
        c.winnerBonus = toWinners;
        treasuryOwed += toTreasury;
        liveChallenge[c.ticker] = 0;

        if (challengerWon) {
            address oldKing = _kings[c.ticker].token;
            _kings[c.ticker] = King({
                token: c.challengerToken, beneficiary: c.challengerBeneficiary, reignStartedAt: uint64(block.timestamp)
            });
            tickerTotals[c.ticker].dethronements += 1;
            emit Dethroned(challengeId, c.ticker, c.challengerToken, oldKing, c.kingStake, c.challengerStake);
            emit Crowned(c.ticker, c.challengerToken, c.challengerBeneficiary, uint64(block.timestamp));
        } else {
            cooldownUntil[c.ticker] = uint64(block.timestamp) + COOLDOWN;
            emit ChallengeFailed(challengeId, c.ticker, c.kingStake, c.challengerStake);
        }
    }

    /// @notice Pull everything the caller is owed from a finalized challenge (both sides at once).
    function claim(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        if (c.openedAt == 0) revert UnknownChallenge(challengeId);
        if (!c.finalized) revert NotFinalized(challengeId);
        uint256 amount = claimable(challengeId, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[challengeId][msg.sender] = true;
        emit Claimed(challengeId, msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Send everything owed to `TREASURY`. Anyone may call.
    function withdrawTreasury() external {
        uint256 amount = treasuryOwed;
        if (amount == 0) revert NothingToClaim();
        treasuryOwed = 0;
        emit TreasuryWithdrawn(amount);
        (bool ok,) = TREASURY.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ---------------------------------------------------------------- internals

    function _crown(bytes32 ticker, address token, address beneficiary) internal {
        if (ticker == bytes32(0)) revert ZeroTicker();
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        _kings[ticker] = King({token: token, beneficiary: beneficiary, reignStartedAt: uint64(block.timestamp)});
        emit Crowned(ticker, token, beneficiary, uint64(block.timestamp));
    }

    function _stake(uint256 challengeId, Challenge storage c, Side side, uint256 amount) internal {
        if (side == Side.King) {
            c.kingStake += amount;
            kingStakeOf[challengeId][msg.sender] += amount;
            tickerTotals[c.ticker].kingStakedEver += amount;
        } else {
            c.challengerStake += amount;
            challengerStakeOf[challengeId][msg.sender] += amount;
            tickerTotals[c.ticker].challengerStakedEver += amount;
        }
        emit Staked(challengeId, msg.sender, side, amount);
    }
}
