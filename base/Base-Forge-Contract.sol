// =============================================================================
// VinculumFinalisSynth — SYNTH Token + Forge Mechanism (BASE-TOK + BASE-FORGE)
//
// PROVENANCE: Built directly from Revision 6 authoritative documents:
//   - 227826f11_Vinculum_Finalis_Master_Specification_Revision_6_2026-07-28.docx (Revision 6)
//   - Vinculum_Finalis_Protocol_Constants.json (Revision 6, 2026-07-28)
//
// Requirements implemented:
//   VF-TOK-001: 18 decimal places for SYNTH
//   VF-TOK-003: SYNTH activation is permanent when cumulative lifetime CHONX
//               issuance reaches 100,000,000
//   VF-TOK-004: Forging one SYNTH permanently destroys exactly 1,000 VCLM and
//               10,000 CHONX
//   VF-TOK-010: SYNTH hard cap = 10,000,000 (10 million)
//   VF-SUP-015: Hard-cap rejection in full — forge reverts if cap exceeded
//
// The SYNTH token is NOT minted by the verifier. It is minted ONLY through the
// forge() function, which atomically burns VCLM + CHONX from the caller.
//
// SPDX-License-Identifier: PROTOCOL-RESTRICTED
// Solidity 0.8.19+
// =============================================================================

pragma solidity 0.8.19;

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------

interface IVerifier {
    function cumulativeChonxIssued() external view returns (uint256);
    function chonxActivated() external view returns (bool);
}

interface IBurnableToken {
    function burnFrom(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

// ---------------------------------------------------------------------------
// VinculumFinalisSynth — SYNTH token with built-in forge mechanism
// ---------------------------------------------------------------------------

contract VinculumFinalisSynth {

    // ===== Token metadata =====
    string public constant name = "Vinculum Finalis SYNTH";
    string public constant symbol = "SYNTH";
    uint8 public constant decimals = 18; // VF-TOK-001

    // ===== Protocol constants (verbatim from Revision 6) =====

    // VF-TOK-010: SYNTH hard cap = 10,000,000
    uint256 public constant HARD_CAP = 10_000_000 * 1e18;

    // VF-TOK-004: Forging one SYNTH permanently destroys exactly 1,000 VCLM and 10,000 CHONX
    uint256 public constant VCLM_BURN_PER_SYNTH = 1000 * 1e18;
    uint256 public constant CHONX_BURN_PER_SYNTH = 10000 * 1e18;

    // VF-TOK-003: SYNTH activation is permanent when cumulative CHONX reaches 100,000,000
    uint256 public constant SYNTH_ACTIVATION_THRESHOLD = 100_000_000 * 1e18;

    // ===== External contract references =====
    IVerifier public immutable verifier;
    IBurnableToken public immutable vclmToken;
    IBurnableToken public immutable chonxToken;

    // ===== Activation state =====
    bool public synthActivated;
    uint256 public synthActivationBlock;

    // ===== ERC-20 state =====
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ===== Events =====
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SynthForged(address indexed forger, uint256 count, uint256 vclmBurned, uint256 chonxBurned);
    event SynthActivated(uint256 activationBlock);


    // ===== Constructor =====
    /// @param _verifier Address of the VinculumFinalisVerifier contract
    /// @param _vclmToken Address of the VCLM token contract
    /// @param _chonxToken Address of the CHONX token contract
    constructor(
        address _verifier,
        address _vclmToken,
        address _chonxToken
    ) {
        // VF-DEP-002: zero configuration cannot be finalized.
        require(_verifier != address(0), "VF-DEP-002: zero verifier");
        require(_vclmToken != address(0), "VF-DEP-002: zero VCLM");
        require(_chonxToken != address(0), "VF-DEP-002: zero CHONX");
        verifier = IVerifier(_verifier);
        vclmToken = IBurnableToken(_vclmToken);
        chonxToken = IBurnableToken(_chonxToken);
    }

    // ===== Configuration =====
    //
    // CL-02 / VF-IMM-001/004: REMOVED. setVerifier() and setTokenContracts()
    // allowed the authority to repoint the burn targets after deployment,
    // which is a discretionary parameter-setting authority. All three
    // addresses are now fixed at construction and immutable.

    // ===== SYNTH activation (VF-TOK-003) =====

    /// @notice Checks whether SYNTH activation threshold has been reached.
    /// @dev Activation is permanent — once set, it is never unset.
    ///      Reads cumulativeChonxIssued from the verifier contract.
    /// @return Whether SYNTH is activated.
    function checkActivation() public returns (bool) {
        if (synthActivated) return true;
        if (verifier.cumulativeChonxIssued() >= SYNTH_ACTIVATION_THRESHOLD) {
            synthActivated = true;
            synthActivationBlock = block.number;
            emit SynthActivated(block.number);
            return true;
        }
        return false;
    }

    /// @notice View function to check if activation threshold has been reached
    ///         without mutating state.
    function isActivationThresholdReached() external view returns (bool) {
        return verifier.cumulativeChonxIssued() >= SYNTH_ACTIVATION_THRESHOLD;
    }

    // ===== SYNTH forge (VF-TOK-004) =====

    /// @notice Forges SYNTH by permanently destroying VCLM and CHONX.
    /// @dev Caller must have approved this contract to spend VCLM and CHONX.
    /// @param count Number of SYNTH tokens to forge (each burns 1,000 VCLM + 10,000 CHONX).
    /// @return success Always true on success (reverts on failure).
    function forge(uint256 count) external returns (bool success) {
        require(count > 0, "SYNTH: zero forge count");

        // VF-TOK-003: SYNTH must be activated
        require(checkActivation(), "VF-TOK-003: SYNTH not activated");

        uint256 vclmToBurn = VCLM_BURN_PER_SYNTH * count;
        uint256 chonxToBurn = CHONX_BURN_PER_SYNTH * count;
        uint256 synthToMint = count * 1e18; // 18 decimals per SYNTH (VF-TOK-001)

        // VF-SUP-015: Hard-cap rejection in full
        require(
            totalSupply + synthToMint <= HARD_CAP,
            "VF-SUP-015: SYNTH hard cap exceeded - reject in full"
        );

        // VF-TOK-004: Permanently destroy VCLM and CHONX
        // burnFrom reverts if insufficient balance or allowance
        vclmToken.burnFrom(msg.sender, vclmToBurn);
        chonxToken.burnFrom(msg.sender, chonxToBurn);

        // Mint SYNTH to caller
        totalSupply += synthToMint;
        balanceOf[msg.sender] += synthToMint;

        emit SynthForged(msg.sender, count, vclmToBurn, chonxToBurn);
        emit Transfer(address(0), msg.sender, synthToMint);
        return true;
    }

    // ===== Standard ERC-20 =====

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "SYNTH: transfer to zero address");
        require(balanceOf[msg.sender] >= amount, "SYNTH: insufficient balance");
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "SYNTH: transfer to zero address");
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "SYNTH: insufficient allowance");
        require(balanceOf[from] >= amount, "SYNTH: insufficient balance");
        allowance[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}