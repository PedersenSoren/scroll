// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {EmptyContract} from "../../src/misc/EmptyContract.sol";

import {EnforcedTxGateway} from "../../src/L1/gateways/EnforcedTxGateway.sol";
import {L1CustomERC20Gateway} from "../../src/L1/gateways/L1CustomERC20Gateway.sol";
import {L1ERC1155Gateway} from "../../src/L1/gateways/L1ERC1155Gateway.sol";
import {L1ERC721Gateway} from "../../src/L1/gateways/L1ERC721Gateway.sol";
import {L1ETHGateway} from "../../src/L1/gateways/L1ETHGateway.sol";
import {L1GatewayRouter} from "../../src/L1/gateways/L1GatewayRouter.sol";
import {L1MessageQueueWithGasPriceOracle} from "../../src/L1/rollup/L1MessageQueueWithGasPriceOracle.sol";
import {L1ScrollMessenger} from "../../src/L1/L1ScrollMessenger.sol";
import {L1StandardERC20Gateway} from "../../src/L1/gateways/L1StandardERC20Gateway.sol";
import {L1WETHGateway} from "../../src/L1/gateways/L1WETHGateway.sol";
import {L2GasPriceOracle} from "../../src/L1/rollup/L2GasPriceOracle.sol";
import {MultipleVersionRollupVerifier} from "../../src/L1/rollup/MultipleVersionRollupVerifier.sol";
import {ScrollChain} from "../../src/L1/rollup/ScrollChain.sol";
import {ZkEvmVerifierV1} from "../../src/libraries/verifier/ZkEvmVerifierV1.sol";

import {L2CustomERC20Gateway} from "../../src/L2/gateways/L2CustomERC20Gateway.sol";
import {L2ERC1155Gateway} from "../../src/L2/gateways/L2ERC1155Gateway.sol";
import {L2ERC721Gateway} from "../../src/L2/gateways/L2ERC721Gateway.sol";
import {L2ETHGateway} from "../../src/L2/gateways/L2ETHGateway.sol";
import {L2GatewayRouter} from "../../src/L2/gateways/L2GatewayRouter.sol";
import {L2ScrollMessenger} from "../../src/L2/L2ScrollMessenger.sol";
import {L2StandardERC20Gateway} from "../../src/L2/gateways/L2StandardERC20Gateway.sol";
import {L2WETHGateway} from "../../src/L2/gateways/L2WETHGateway.sol";
import {L1GasPriceOracle} from "../../src/L2/predeploys/L1GasPriceOracle.sol";
import {L2MessageQueue} from "../../src/L2/predeploys/L2MessageQueue.sol";
import {L2TxFeeVault} from "../../src/L2/predeploys/L2TxFeeVault.sol";
import {Whitelist} from "../../src/L2/predeploys/Whitelist.sol";
import {WrappedEther} from "../../src/L2/predeploys/WrappedEther.sol";
import {ScrollStandardERC20} from "../../src/libraries/token/ScrollStandardERC20.sol";
import {ScrollStandardERC20Factory} from "../../src/libraries/token/ScrollStandardERC20Factory.sol";

/// @dev The address of DeterministicDeploymentProxy.
///      See https://github.com/Arachnid/deterministic-deployment-proxy.
address constant DETERMINISTIC_DEPLOYMENT_PROXY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// @dev The default deterministic deployment salt prefix.
string constant DEFAULT_DEPLOYMENT_SALT = "ScrollStack";

/// @dev The default minimum withdraw amount configured on L2TxFeeVault.
uint256 constant FEE_VAULT_MIN_WITHDRAW_AMOUNT = 1 ether;

// configuration file paths
string constant CONFIG_PATH = "./configuration/config.toml";
string constant CONTRACTS_CONFIG_PATH = "./configuration/config-contracts.toml";
string constant GENESIS_ALLOC_JSON_PATH = "./configuration/genesis-alloc.json";
string constant GENESIS_JSON_PATH = "./configuration/genesis.json";

contract ProxyAdminSetOwner is ProxyAdmin {
    /// @dev allow setting the owner in the constructor, otherwise
    ///      DeterministicDeploymentProxy would become the owner.
    constructor(address owner) {
        _transferOwnership(owner);
    }
}

contract MultipleVersionRollupVerifierSetOwner is MultipleVersionRollupVerifier {
    /// @dev allow setting the owner in the constructor, otherwise
    ///      DeterministicDeploymentProxy would become the owner.
    constructor(
        address owner,
        address _scrollChain,
        uint256[] memory _versions,
        address[] memory _verifiers
    ) MultipleVersionRollupVerifier(_scrollChain, _versions, _verifiers) {
        _transferOwnership(owner);
    }
}

contract ScrollStandardERC20FactorySetOwner is ScrollStandardERC20Factory {
    /// @dev allow setting the owner in the constructor, otherwise
    ///      DeterministicDeploymentProxy would become the owner.
    constructor(address owner, address _implementation) ScrollStandardERC20Factory(_implementation) {
        _transferOwnership(owner);
    }
}

contract Configuration is Script {
    using stdToml for string;

    enum ScriptMode {
        None,
        LogAddresses,
        WriteConfig,
        VerifyConfig
    }

    string internal cfg;
    string internal contractsCfg;

    ScriptMode internal mode = ScriptMode.LogAddresses;

    /***************************
     * Configuration parameters *
     ***************************/

    // general
    uint64 internal CHAIN_ID_L1;
    uint64 internal CHAIN_ID_L2;
    uint256 internal MAX_TX_IN_CHUNK;
    uint256 internal MAX_L1_MESSAGE_GAS_LIMIT;

    // accounts
    uint256 internal DEPLOYER_PRIVATE_KEY;

    address internal L1_COMMIT_SENDER_ADDR;
    address internal L1_FINALIZE_SENDER_ADDR;
    address internal L1_GAS_ORACLE_SENDER_ADDR;
    address internal L2_GAS_ORACLE_SENDER_ADDR;

    address internal DEPLOYER_ADDR;
    address internal OWNER_ADDR;

    address internal L2GETH_SIGNER_0_ADDRESS;

    // genesis
    uint256 internal L2_MAX_ETH_SUPPLY;
    uint256 internal L2_DEPLOYER_INITIAL_BALANCE;
    uint256 internal L2_SCROLL_MESSENGER_INITIAL_BALANCE;

    // contracts
    string internal DEPLOYMENT_SALT;

    address internal L1_FEE_VAULT_ADDR;
    address internal L1_PLONK_VERIFIER_ADDR;

    /***************
     * Constructor *
     **************/

    constructor() {
        cfg = vm.readFile(CONFIG_PATH);
        contractsCfg = vm.readFile(CONTRACTS_CONFIG_PATH);

        DEPLOYMENT_SALT = cfg.readString(".contracts.DEPLOYMENT_SALT");

        CHAIN_ID_L1 = uint64(cfg.readUint(".general.CHAIN_ID_L1"));
        CHAIN_ID_L2 = uint64(cfg.readUint(".general.CHAIN_ID_L2"));
        MAX_TX_IN_CHUNK = cfg.readUint(".general.MAX_TX_IN_CHUNK");
        MAX_L1_MESSAGE_GAS_LIMIT = cfg.readUint(".general.MAX_L1_MESSAGE_GAS_LIMIT");

        DEPLOYER_PRIVATE_KEY = cfg.readUint(".accounts.DEPLOYER_PRIVATE_KEY");
        DEPLOYER_ADDR = cfg.readAddress(".accounts.DEPLOYER_ADDR");

        // config sanity check
        if (vm.addr(DEPLOYER_PRIVATE_KEY) != DEPLOYER_ADDR) {
            console.log(string(abi.encodePacked("[ERROR] DEPLOYER_ADDR does not match DEPLOYER_PRIVATE_KEY")));
            revert();
        }

        OWNER_ADDR = cfg.readAddress(".accounts.OWNER_ADDR");

        L1_COMMIT_SENDER_ADDR = cfg.readAddress(".accounts.L1_COMMIT_SENDER_ADDR");
        L1_FINALIZE_SENDER_ADDR = cfg.readAddress(".accounts.L1_FINALIZE_SENDER_ADDR");
        L1_GAS_ORACLE_SENDER_ADDR = cfg.readAddress(".accounts.L1_GAS_ORACLE_SENDER_ADDR");
        L2_GAS_ORACLE_SENDER_ADDR = cfg.readAddress(".accounts.L2_GAS_ORACLE_SENDER_ADDR");
        L2GETH_SIGNER_0_ADDRESS = cfg.readAddress(".accounts.L2GETH_SIGNER_0_ADDRESS");

        L1_FEE_VAULT_ADDR = cfg.readAddress(".contracts.L1_FEE_VAULT_ADDR");
        L1_PLONK_VERIFIER_ADDR = cfg.readAddress(".contracts.L1_PLONK_VERIFIER_ADDR");

        L2_MAX_ETH_SUPPLY = cfg.readUint(".genesis.L2_MAX_ETH_SUPPLY");
        L2_DEPLOYER_INITIAL_BALANCE = cfg.readUint(".genesis.L2_DEPLOYER_INITIAL_BALANCE");
        L2_SCROLL_MESSENGER_INITIAL_BALANCE = L2_MAX_ETH_SUPPLY - L2_DEPLOYER_INITIAL_BALANCE;
    }

    /*************
     * Utilities *
     ************/

    function parseScriptMode(string memory raw) internal pure returns (ScriptMode) {
        if (keccak256(bytes(raw)) == keccak256(bytes("log-addresses"))) {
            return ScriptMode.WriteConfig;
        } else if (keccak256(bytes(raw)) == keccak256(bytes("write-config"))) {
            return ScriptMode.WriteConfig;
        } else if (keccak256(bytes(raw)) == keccak256(bytes("verify-config"))) {
            return ScriptMode.VerifyConfig;
        } else {
            return ScriptMode.None;
        }
    }

    /// @dev Ensure that `addr` is not the zero address.
    ///      This helps catch bugs arising from incorrect deployment order.
    function notnull(address addr) internal pure returns (address) {
        require(addr != address(0), "null address");
        return addr;
    }

    function label(string memory name, address addr) internal {
        vm.label(addr, name);

        if (mode == ScriptMode.LogAddresses) {
            console.log(string(abi.encodePacked(name, "_ADDR=", vm.toString(address(addr)))));
        }

        string memory tomlPath = string(abi.encodePacked(".", name, "_ADDR"));

        if (mode == ScriptMode.WriteConfig) {
            vm.writeToml(vm.toString(addr), CONTRACTS_CONFIG_PATH, tomlPath);
        }

        if (mode == ScriptMode.VerifyConfig) {
            address expectedAddr = contractsCfg.readAddress(tomlPath);

            if (addr != expectedAddr) {
                console.log(
                    string(
                        abi.encodePacked(
                            "[ERROR] unexpected address for ",
                            name,
                            ", expected = ",
                            vm.toString(expectedAddr),
                            " (from toml config), got = ",
                            vm.toString(addr)
                        )
                    )
                );

                revert();
            }
        }
    }
}

contract DeterminsticDeploymentScript is Configuration {
    using stdToml for string;

    string private SALT_PREFIX;
    bool internal SKIP_DEPLOY = false;

    constructor() {
        // salt prefix used for deterministic deployments
        if (bytes(DEPLOYMENT_SALT).length != 0) {
            SALT_PREFIX = DEPLOYMENT_SALT;
        } else {
            SALT_PREFIX = DEFAULT_DEPLOYMENT_SALT;
        }

        // sanity check: make sure DeterministicDeploymentProxy exists
        if (DETERMINISTIC_DEPLOYMENT_PROXY_ADDR.code.length == 0) {
            console.log(
                string(
                    abi.encodePacked(
                        "[ERROR] DeterministicDeploymentProxy (",
                        vm.toString(DETERMINISTIC_DEPLOYMENT_PROXY_ADDR),
                        ") is not available"
                    )
                )
            );
            revert();
        }
    }

    function deploy(string memory name, bytes memory codeWithArgs) internal returns (address) {
        return _deploy(name, codeWithArgs);
    }

    function deploy(
        string memory name,
        bytes memory code,
        bytes memory args
    ) internal returns (address) {
        return _deploy(name, abi.encodePacked(code, args));
    }

    function predict(string memory name, bytes memory codeWithArgs) internal view returns (address) {
        return _predict(name, codeWithArgs);
    }

    function predict(
        string memory name,
        bytes memory code,
        bytes memory args
    ) internal view returns (address) {
        return _predict(name, abi.encodePacked(code, args));
    }

    function _deploy(string memory name, bytes memory codeWithArgs) private returns (address) {
        // check override (mainly used with predeploys)
        address addr = tryGetOverride(name);

        if (addr != address(0)) {
            label(name, addr);
            return addr;
        }

        // predict determinstic deployment address
        addr = _predict(name, codeWithArgs);
        label(name, addr);

        if (SKIP_DEPLOY) {
            return addr;
        }

        // return if the contract is already deployed,
        // in this case the subsequent initialization steps will probably break
        if (addr.code.length > 0) {
            console.log(string(abi.encodePacked("[WARN] contract ", name, " is already deployed")));
            return addr;
        }

        // deploy contract
        bytes32 salt = _getSalt(name);
        bytes memory data = abi.encodePacked(salt, codeWithArgs);
        (bool success, ) = DETERMINISTIC_DEPLOYMENT_PROXY_ADDR.call(data);
        require(success, "call failed");
        require(addr.code.length != 0, "deployment address mismatch");

        return addr;
    }

    function tryGetOverride(string memory name) internal returns (address) {
        address addr;
        string memory key = string(abi.encodePacked(".contracts.overrides.", name));

        if (!vm.keyExistsToml(cfg, key)) {
            return address(0);
        }

        addr = cfg.readAddress(key);

        if (addr.code.length == 0) {
            (VmSafe.CallerMode callerMode, , ) = vm.readCallers();

            // if we're ready to start broadcasting transactions, then we
            // must ensure that the override contract has been deployed.
            if (callerMode == VmSafe.CallerMode.Broadcast || callerMode == VmSafe.CallerMode.RecurrentBroadcast) {
                console.log(
                    string(
                        abi.encodePacked(
                            "[ERROR] override ",
                            name,
                            " = ",
                            vm.toString(addr),
                            " not deployed in broadcast mode"
                        )
                    )
                );
                revert();
            }
        }

        return addr;
    }

    function _getSalt(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_PREFIX, name));
    }

    function _predict(string memory name, bytes memory codeWithArgs) private view returns (address) {
        bytes32 salt = _getSalt(name);

        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                DETERMINISTIC_DEPLOYMENT_PROXY_ADDR,
                                salt,
                                keccak256(codeWithArgs)
                            )
                        )
                    )
                )
            );
    }
}

contract DeployScroll is DeterminsticDeploymentScript {
    enum Layer {
        None,
        L1,
        L2
    }

    /***************************
     * Configuration parameters *
     ***************************/

    // general configurations
    Layer internal BROADCAST_LAYER = Layer.None;

    /**********************
     * Contracts to deploy *
     **********************/

    // L1 addresses
    address internal L1_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR;
    address internal L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_ENFORCED_TX_GATEWAY_PROXY_ADDR;
    address internal L1_ERC1155_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_ERC1155_GATEWAY_PROXY_ADDR;
    address internal L1_ERC721_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_ERC721_GATEWAY_PROXY_ADDR;
    address internal L1_ETH_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_ETH_GATEWAY_PROXY_ADDR;
    address internal L1_GATEWAY_ROUTER_IMPLEMENTATION_ADDR;
    address internal L1_GATEWAY_ROUTER_PROXY_ADDR;
    address internal L1_MESSAGE_QUEUE_IMPLEMENTATION_ADDR;
    address internal L1_MESSAGE_QUEUE_PROXY_ADDR;
    address internal L1_MULTIPLE_VERSION_ROLLUP_VERIFIER_ADDR;
    address internal L1_PROXY_ADMIN_ADDR;
    address internal L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR;
    address internal L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR;
    address internal L1_SCROLL_CHAIN_PROXY_ADDR;
    address internal L1_SCROLL_MESSENGER_IMPLEMENTATION_ADDR;
    address internal L1_SCROLL_MESSENGER_PROXY_ADDR;
    address internal L1_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR;
    address internal L1_WETH_ADDR;
    address internal L1_WETH_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L1_WETH_GATEWAY_PROXY_ADDR;
    address internal L1_WHITELIST_ADDR;
    address internal L1_ZKEVM_VERIFIER_V1_ADDR;
    address internal L2_GAS_PRICE_ORACLE_IMPLEMENTATION_ADDR;
    address internal L2_GAS_PRICE_ORACLE_PROXY_ADDR;

    // L2 addresses
    address internal L1_GAS_PRICE_ORACLE_ADDR;
    address internal L2_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR;
    address internal L2_ERC1155_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L2_ERC1155_GATEWAY_PROXY_ADDR;
    address internal L2_ERC721_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L2_ERC721_GATEWAY_PROXY_ADDR;
    address internal L2_ETH_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L2_ETH_GATEWAY_PROXY_ADDR;
    address internal L2_GATEWAY_ROUTER_IMPLEMENTATION_ADDR;
    address internal L2_GATEWAY_ROUTER_PROXY_ADDR;
    address internal L2_MESSAGE_QUEUE_ADDR;
    address internal L2_PROXY_ADMIN_ADDR;
    address internal L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR;
    address internal L2_SCROLL_MESSENGER_IMPLEMENTATION_ADDR;
    address internal L2_SCROLL_MESSENGER_PROXY_ADDR;
    address internal L2_SCROLL_STANDARD_ERC20_ADDR;
    address internal L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR;
    address internal L2_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR;
    address internal L2_TX_FEE_VAULT_ADDR;
    address internal L2_WETH_ADDR;
    address internal L2_WETH_GATEWAY_IMPLEMENTATION_ADDR;
    address internal L2_WETH_GATEWAY_PROXY_ADDR;
    address internal L2_WHITELIST_ADDR;

    /************
     * Utilities *
     ************/

    function parseLayer(string memory raw) internal pure returns (Layer) {
        if (keccak256(bytes(raw)) == keccak256(bytes("L1"))) {
            return Layer.L1;
        } else if (keccak256(bytes(raw)) == keccak256(bytes("L2"))) {
            return Layer.L2;
        } else {
            return Layer.None;
        }
    }

    /// @dev Only broadcast code block if we run the script on the specified layer.
    modifier broadcast(Layer layer) {
        if (BROADCAST_LAYER == layer) {
            vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
        } else {
            // make sure we use the correct sender in simulation
            vm.startPrank(DEPLOYER_ADDR);
        }

        _;

        if (BROADCAST_LAYER == layer) {
            vm.stopBroadcast();
        } else {
            vm.stopPrank();
        }
    }

    /// @dev Only execute block if we run the script on the specified layer.
    modifier only(Layer layer) {
        if (BROADCAST_LAYER != layer) {
            return;
        }
        _;
    }

    /***************
     * Entry point *
     **************/

    function run(string memory layer, string memory scriptMode) public {
        BROADCAST_LAYER = parseLayer(layer);
        mode = parseScriptMode(scriptMode);

        deployAllContracts();
        initializeL1Contracts();
        initializeL2Contracts();
    }

    function deployAllContracts() internal {
        deployL1Contracts1stPass();
        deployL2Contracts1stPass();
        deployL1Contracts2ndPass();
        deployL2Contracts2ndPass();
    }

    // @notice deployL1Contracts1stPass deploys L1 contracts whose initialization does not depend on any L2 addresses.
    function deployL1Contracts1stPass() internal broadcast(Layer.L1) {
        deployL1Weth();
        deployL1ProxyAdmin();
        deployL1PlaceHolder();
        deployL1Whitelist();
        deployL2GasPriceOracle();
        deployL1ScrollChainProxy();
        deployL1ScrollMessengerProxy();
        deployL1EnforcedTxGateway();
        deployL1ZkEvmVerifierV1();
        deployL1MultipleVersionRollupVerifier();
        deployL1MessageQueue();
        deployL1ScrollChain();
        deployL1GatewayRouter();
        deployL1ETHGatewayProxy();
        deployL1WETHGatewayProxy();
        deployL1StandardERC20GatewayProxy();
        deployL1CustomERC20GatewayProxy();
        deployL1ERC721GatewayProxy();
        deployL1ERC1155GatewayProxy();
    }

    // @notice deployL2Contracts1stPass deploys L2 contracts whose initialization does not depend on any L1 addresses.
    function deployL2Contracts1stPass() internal broadcast(Layer.L2) {
        deployL2MessageQueue();
        deployL1GasPriceOracle();
        deployL2Whitelist();
        deployL2Weth();
        deployTxFeeVault();
        deployL2ProxyAdmin();
        deployL2PlaceHolder();
        deployL2ScrollMessengerProxy();
        deployL2ETHGatewayProxy();
        deployL2WETHGatewayProxy();
        deployL2StandardERC20GatewayProxy();
        deployL2CustomERC20GatewayProxy();
        deployL2ERC721GatewayProxy();
        deployL2ERC1155GatewayProxy();
        deployScrollStandardERC20Factory();
    }

    // @notice deployL1Contracts2ndPass deploys L1 contracts whose initialization depends on some L2 addresses.
    function deployL1Contracts2ndPass() internal broadcast(Layer.L1) {
        deployL1ScrollMessenger();
        deployL1StandardERC20Gateway();
        deployL1ETHGateway();
        deployL1WETHGateway();
        deployL1CustomERC20Gateway();
        deployL1ERC721Gateway();
        deployL1ERC1155Gateway();
    }

    // @notice deployL2Contracts2ndPass deploys L2 contracts whose initialization depends on some L1 addresses.
    function deployL2Contracts2ndPass() internal broadcast(Layer.L2) {
        // upgradable
        deployL2ScrollMessenger();
        deployL2GatewayRouter();
        deployL2StandardERC20Gateway();
        deployL2ETHGateway();
        deployL2WETHGateway();
        deployL2CustomERC20Gateway();
        deployL2ERC721Gateway();
        deployL2ERC1155Gateway();
    }

    // @notice initializeL1Contracts initializes contracts deployed on L1.
    function initializeL1Contracts() internal broadcast(Layer.L1) only(Layer.L1) {
        initializeScrollChain();
        initializeL2GasPriceOracle();
        initializeL1MessageQueue();
        initializeL1ScrollMessenger();
        initializeEnforcedTxGateway();
        initializeL1GatewayRouter();
        initializeL1CustomERC20Gateway();
        initializeL1ERC1155Gateway();
        initializeL1ERC721Gateway();
        initializeL1ETHGateway();
        initializeL1StandardERC20Gateway();
        initializeL1WETHGateway();
        initializeL1Whitelist();

        transferL1ContractOwnership();
    }

    // @notice initializeL2Contracts initializes contracts deployed on L2.
    function initializeL2Contracts() internal broadcast(Layer.L2) only(Layer.L2) {
        initializeL2MessageQueue();
        initializeL2TxFeeVault();
        initializeL1GasPriceOracle();
        initializeL2ScrollMessenger();
        initializeL2GatewayRouter();
        initializeL2CustomERC20Gateway();
        initializeL2ERC1155Gateway();
        initializeL2ERC721Gateway();
        initializeL2ETHGateway();
        initializeL2StandardERC20Gateway();
        initializeL2WETHGateway();
        initializeScrollStandardERC20Factory();
        initializeL2Whitelist();

        transferL2ContractOwnership();
    }

    /***************************
     * L1: 1st pass deployment *
     **************************/

    function deployL1Weth() internal {
        L1_WETH_ADDR = deploy("L1_WETH", type(WrappedEther).creationCode);
    }

    function deployL1ProxyAdmin() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        L1_PROXY_ADMIN_ADDR = deploy("L1_PROXY_ADMIN", type(ProxyAdminSetOwner).creationCode, args);
    }

    function deployL1PlaceHolder() internal {
        L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR = deploy(
            "L1_PROXY_IMPLEMENTATION_PLACEHOLDER",
            type(EmptyContract).creationCode
        );
    }

    function deployL1Whitelist() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        L1_WHITELIST_ADDR = deploy("L1_WHITELIST", type(Whitelist).creationCode, args);
    }

    function deployL2GasPriceOracle() internal {
        L2_GAS_PRICE_ORACLE_IMPLEMENTATION_ADDR = deploy(
            "L2_GAS_PRICE_ORACLE_IMPLEMENTATION",
            type(L2GasPriceOracle).creationCode
        );

        bytes memory args = abi.encode(
            notnull(L2_GAS_PRICE_ORACLE_IMPLEMENTATION_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_GAS_PRICE_ORACLE_PROXY_ADDR = deploy(
            "L2_GAS_PRICE_ORACLE_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1ScrollChainProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_SCROLL_CHAIN_PROXY_ADDR = deploy(
            "L1_SCROLL_CHAIN_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1ScrollMessengerProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_SCROLL_MESSENGER_PROXY_ADDR = deploy(
            "L1_SCROLL_MESSENGER_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1EnforcedTxGateway() internal {
        L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION",
            type(EnforcedTxGateway).creationCode
        );

        bytes memory args = abi.encode(
            notnull(L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_ENFORCED_TX_GATEWAY_PROXY_ADDR = deploy(
            "L1_ENFORCED_TX_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1ZkEvmVerifierV1() internal {
        bytes memory args = abi.encode(notnull(L1_PLONK_VERIFIER_ADDR));
        L1_ZKEVM_VERIFIER_V1_ADDR = deploy("L1_ZKEVM_VERIFIER_V1", type(ZkEvmVerifierV1).creationCode, args);
    }

    function deployL1MultipleVersionRollupVerifier() internal {
        uint256[] memory _versions = new uint256[](1);
        address[] memory _verifiers = new address[](1);
        _versions[0] = 1;
        _verifiers[0] = notnull(L1_ZKEVM_VERIFIER_V1_ADDR);

        bytes memory args = abi.encode(DEPLOYER_ADDR, notnull(L1_SCROLL_CHAIN_PROXY_ADDR), _versions, _verifiers);

        L1_MULTIPLE_VERSION_ROLLUP_VERIFIER_ADDR = deploy(
            "L1_MULTIPLE_VERSION_ROLLUP_VERIFIER",
            type(MultipleVersionRollupVerifierSetOwner).creationCode,
            args
        );
    }

    function deployL1MessageQueue() internal {
        bytes memory args = abi.encode(
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L1_SCROLL_CHAIN_PROXY_ADDR),
            notnull(L1_ENFORCED_TX_GATEWAY_PROXY_ADDR)
        );

        L1_MESSAGE_QUEUE_IMPLEMENTATION_ADDR = deploy(
            "L1_MESSAGE_QUEUE_IMPLEMENTATION",
            type(L1MessageQueueWithGasPriceOracle).creationCode,
            args
        );

        bytes memory args2 = abi.encode(
            notnull(L1_MESSAGE_QUEUE_IMPLEMENTATION_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_MESSAGE_QUEUE_PROXY_ADDR = deploy(
            "L1_MESSAGE_QUEUE_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args2
        );
    }

    function deployL1ScrollChain() internal {
        bytes memory args = abi.encode(
            CHAIN_ID_L2,
            notnull(L1_MESSAGE_QUEUE_PROXY_ADDR),
            notnull(L1_MULTIPLE_VERSION_ROLLUP_VERIFIER_ADDR)
        );

        L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR = deploy(
            "L1_SCROLL_CHAIN_IMPLEMENTATION",
            type(ScrollChain).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_SCROLL_CHAIN_PROXY_ADDR)),
            notnull(L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1GatewayRouter() internal {
        L1_GATEWAY_ROUTER_IMPLEMENTATION_ADDR = deploy(
            "L1_GATEWAY_ROUTER_IMPLEMENTATION",
            type(L1GatewayRouter).creationCode
        );

        bytes memory args = abi.encode(
            notnull(L1_GATEWAY_ROUTER_IMPLEMENTATION_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_GATEWAY_ROUTER_PROXY_ADDR = deploy(
            "L1_GATEWAY_ROUTER_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1ETHGatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_ETH_GATEWAY_PROXY_ADDR = deploy(
            "L1_ETH_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1WETHGatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_WETH_GATEWAY_PROXY_ADDR = deploy(
            "L1_WETH_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1StandardERC20GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR = deploy(
            "L1_STANDARD_ERC20_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1CustomERC20GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR = deploy(
            "L1_CUSTOM_ERC20_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1ERC721GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_ERC721_GATEWAY_PROXY_ADDR = deploy(
            "L1_ERC721_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL1ERC1155GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L1_ERC1155_GATEWAY_PROXY_ADDR = deploy(
            "L1_ERC1155_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    /***************************
     * L2: 1st pass deployment *
     **************************/

    function deployL2MessageQueue() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        L2_MESSAGE_QUEUE_ADDR = deploy("L2_MESSAGE_QUEUE", type(L2MessageQueue).creationCode, args);
    }

    function deployL1GasPriceOracle() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        L1_GAS_PRICE_ORACLE_ADDR = deploy("L1_GAS_PRICE_ORACLE", type(L1GasPriceOracle).creationCode, args);
    }

    function deployL2Whitelist() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        L2_WHITELIST_ADDR = deploy("L2_WHITELIST", type(Whitelist).creationCode, args);
    }

    function deployL2Weth() internal {
        L2_WETH_ADDR = deploy("L2_WETH", type(WrappedEther).creationCode);
    }

    function deployTxFeeVault() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR, L1_FEE_VAULT_ADDR, FEE_VAULT_MIN_WITHDRAW_AMOUNT);
        L2_TX_FEE_VAULT_ADDR = deploy("L2_TX_FEE_VAULT", type(L2TxFeeVault).creationCode, args);
    }

    function deployL2ProxyAdmin() internal {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        L2_PROXY_ADMIN_ADDR = deploy("L2_PROXY_ADMIN", type(ProxyAdminSetOwner).creationCode, args);
    }

    function deployL2PlaceHolder() internal {
        L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR = deploy(
            "L2_PROXY_IMPLEMENTATION_PLACEHOLDER",
            type(EmptyContract).creationCode
        );
    }

    function deployL2ScrollMessengerProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_SCROLL_MESSENGER_PROXY_ADDR = deploy(
            "L2_SCROLL_MESSENGER_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2StandardERC20GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR = deploy(
            "L2_STANDARD_ERC20_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2ETHGatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_ETH_GATEWAY_PROXY_ADDR = deploy(
            "L2_ETH_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2WETHGatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_WETH_GATEWAY_PROXY_ADDR = deploy(
            "L2_WETH_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2CustomERC20GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR = deploy(
            "L2_CUSTOM_ERC20_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2ERC721GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_ERC721_GATEWAY_PROXY_ADDR = deploy(
            "L2_ERC721_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2ERC1155GatewayProxy() internal {
        bytes memory args = abi.encode(
            notnull(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_ERC1155_GATEWAY_PROXY_ADDR = deploy(
            "L2_ERC1155_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployScrollStandardERC20Factory() internal {
        L2_SCROLL_STANDARD_ERC20_ADDR = deploy("L2_SCROLL_STANDARD_ERC20", type(ScrollStandardERC20).creationCode);
        bytes memory args = abi.encode(DEPLOYER_ADDR, notnull(L2_SCROLL_STANDARD_ERC20_ADDR));

        L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR = deploy(
            "L2_SCROLL_STANDARD_ERC20_FACTORY",
            type(ScrollStandardERC20FactorySetOwner).creationCode,
            args
        );
    }

    /***************************
     * L1: 2nd pass deployment *
     **************************/

    function deployL1ScrollMessenger() internal {
        bytes memory args = abi.encode(
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L1_SCROLL_CHAIN_PROXY_ADDR),
            notnull(L1_MESSAGE_QUEUE_PROXY_ADDR)
        );

        L1_SCROLL_MESSENGER_IMPLEMENTATION_ADDR = deploy(
            "L1_SCROLL_MESSENGER_IMPLEMENTATION",
            type(L1ScrollMessenger).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)),
            notnull(L1_SCROLL_MESSENGER_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1ETHGateway() internal {
        bytes memory args = abi.encode(
            notnull(L2_ETH_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );

        L1_ETH_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_ETH_GATEWAY_IMPLEMENTATION",
            type(L1ETHGateway).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_ETH_GATEWAY_PROXY_ADDR)),
            notnull(L1_ETH_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1WETHGateway() internal {
        bytes memory args = abi.encode(
            notnull(L1_WETH_ADDR),
            notnull(L2_WETH_ADDR),
            notnull(L2_WETH_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );

        L1_WETH_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_WETH_GATEWAY_IMPLEMENTATION",
            type(L1WETHGateway).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_WETH_GATEWAY_PROXY_ADDR)),
            notnull(L1_WETH_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1StandardERC20Gateway() internal {
        bytes memory args = abi.encode(
            notnull(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L2_SCROLL_STANDARD_ERC20_ADDR),
            notnull(L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR)
        );

        L1_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_STANDARD_ERC20_GATEWAY_IMPLEMENTATION",
            type(L1StandardERC20Gateway).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR)),
            notnull(L1_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1CustomERC20Gateway() internal {
        bytes memory args = abi.encode(
            notnull(L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );

        L1_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION",
            type(L1CustomERC20Gateway).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR)),
            notnull(L1_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1ERC721Gateway() internal {
        bytes memory args = abi.encode(notnull(L2_ERC721_GATEWAY_PROXY_ADDR), notnull(L1_SCROLL_MESSENGER_PROXY_ADDR));

        L1_ERC721_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_ERC721_GATEWAY_IMPLEMENTATION",
            type(L1ERC721Gateway).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_ERC721_GATEWAY_PROXY_ADDR)),
            notnull(L1_ERC721_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL1ERC1155Gateway() internal {
        bytes memory args = abi.encode(notnull(L2_ERC1155_GATEWAY_PROXY_ADDR), notnull(L1_SCROLL_MESSENGER_PROXY_ADDR));

        L1_ERC1155_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L1_ERC1155_GATEWAY_IMPLEMENTATION",
            type(L1ERC1155Gateway).creationCode,
            args
        );

        ProxyAdmin(L1_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L1_ERC1155_GATEWAY_PROXY_ADDR)),
            notnull(L1_ERC1155_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    /***************************
     * L2: 2nd pass deployment *
     **************************/

    function deployL2ScrollMessenger() internal {
        bytes memory args = abi.encode(notnull(L1_SCROLL_MESSENGER_PROXY_ADDR), notnull(L2_MESSAGE_QUEUE_ADDR));

        L2_SCROLL_MESSENGER_IMPLEMENTATION_ADDR = deploy(
            "L2_SCROLL_MESSENGER_IMPLEMENTATION",
            type(L2ScrollMessenger).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)),
            notnull(L2_SCROLL_MESSENGER_IMPLEMENTATION_ADDR)
        );
    }

    function deployL2GatewayRouter() internal {
        L2_GATEWAY_ROUTER_IMPLEMENTATION_ADDR = deploy(
            "L2_GATEWAY_ROUTER_IMPLEMENTATION",
            type(L2GatewayRouter).creationCode
        );

        bytes memory args = abi.encode(
            notnull(L2_GATEWAY_ROUTER_IMPLEMENTATION_ADDR),
            notnull(L2_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        L2_GATEWAY_ROUTER_PROXY_ADDR = deploy(
            "L2_GATEWAY_ROUTER_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );
    }

    function deployL2StandardERC20Gateway() internal {
        bytes memory args = abi.encode(
            notnull(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR)
        );

        L2_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L2_STANDARD_ERC20_GATEWAY_IMPLEMENTATION",
            type(L2StandardERC20Gateway).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR)),
            notnull(L2_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL2ETHGateway() internal {
        bytes memory args = abi.encode(
            notnull(L1_ETH_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );

        L2_ETH_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L2_ETH_GATEWAY_IMPLEMENTATION",
            type(L2ETHGateway).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_ETH_GATEWAY_PROXY_ADDR)),
            notnull(L2_ETH_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL2WETHGateway() internal {
        bytes memory args = abi.encode(
            notnull(L2_WETH_ADDR),
            notnull(L1_WETH_ADDR),
            notnull(L1_WETH_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );

        L2_WETH_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L2_WETH_GATEWAY_IMPLEMENTATION",
            type(L2WETHGateway).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_WETH_GATEWAY_PROXY_ADDR)),
            notnull(L2_WETH_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL2CustomERC20Gateway() internal {
        bytes memory args = abi.encode(
            notnull(L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );

        L2_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L2_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION",
            type(L2CustomERC20Gateway).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR)),
            notnull(L2_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL2ERC721Gateway() internal {
        bytes memory args = abi.encode(notnull(L1_ERC721_GATEWAY_PROXY_ADDR), notnull(L2_SCROLL_MESSENGER_PROXY_ADDR));

        L2_ERC721_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L2_ERC721_GATEWAY_IMPLEMENTATION",
            type(L2ERC721Gateway).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_ERC721_GATEWAY_PROXY_ADDR)),
            notnull(L2_ERC721_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    function deployL2ERC1155Gateway() internal {
        bytes memory args = abi.encode(notnull(L1_ERC1155_GATEWAY_PROXY_ADDR), notnull(L2_SCROLL_MESSENGER_PROXY_ADDR));

        L2_ERC1155_GATEWAY_IMPLEMENTATION_ADDR = deploy(
            "L2_ERC1155_GATEWAY_IMPLEMENTATION",
            type(L2ERC1155Gateway).creationCode,
            args
        );

        ProxyAdmin(L2_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(notnull(L2_ERC1155_GATEWAY_PROXY_ADDR)),
            notnull(L2_ERC1155_GATEWAY_IMPLEMENTATION_ADDR)
        );
    }

    /**********************
     * L1: initialization *
     *********************/

    function initializeScrollChain() internal {
        ScrollChain(L1_SCROLL_CHAIN_PROXY_ADDR).initialize(
            notnull(L1_MESSAGE_QUEUE_PROXY_ADDR),
            notnull(L1_MULTIPLE_VERSION_ROLLUP_VERIFIER_ADDR),
            MAX_TX_IN_CHUNK
        );

        ScrollChain(L1_SCROLL_CHAIN_PROXY_ADDR).addSequencer(L1_COMMIT_SENDER_ADDR);
        ScrollChain(L1_SCROLL_CHAIN_PROXY_ADDR).addProver(L1_FINALIZE_SENDER_ADDR);
    }

    function initializeL2GasPriceOracle() internal {
        L2GasPriceOracle(L2_GAS_PRICE_ORACLE_PROXY_ADDR).initialize(
            21000, // _txGas
            53000, // _txGasContractCreation
            4, // _zeroGas
            16 // _nonZeroGas
        );

        L2GasPriceOracle(L2_GAS_PRICE_ORACLE_PROXY_ADDR).updateWhitelist(L1_WHITELIST_ADDR);
    }

    function initializeL1MessageQueue() internal {
        L1MessageQueueWithGasPriceOracle(L1_MESSAGE_QUEUE_PROXY_ADDR).initialize(
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L1_SCROLL_CHAIN_PROXY_ADDR),
            notnull(L1_ENFORCED_TX_GATEWAY_PROXY_ADDR),
            notnull(L2_GAS_PRICE_ORACLE_PROXY_ADDR),
            MAX_L1_MESSAGE_GAS_LIMIT
        );

        L1MessageQueueWithGasPriceOracle(L1_MESSAGE_QUEUE_PROXY_ADDR).initializeV2();
    }

    function initializeL1ScrollMessenger() internal {
        L1ScrollMessenger(payable(L1_SCROLL_MESSENGER_PROXY_ADDR)).initialize(
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L1_FEE_VAULT_ADDR),
            notnull(L1_SCROLL_CHAIN_PROXY_ADDR),
            notnull(L1_MESSAGE_QUEUE_PROXY_ADDR)
        );
    }

    function initializeEnforcedTxGateway() internal {
        EnforcedTxGateway(payable(L1_ENFORCED_TX_GATEWAY_PROXY_ADDR)).initialize(
            notnull(L1_MESSAGE_QUEUE_PROXY_ADDR),
            notnull(L1_FEE_VAULT_ADDR)
        );

        // disable gateway
        EnforcedTxGateway(payable(L1_ENFORCED_TX_GATEWAY_PROXY_ADDR)).setPause(true);
    }

    function initializeL1GatewayRouter() internal {
        L1GatewayRouter(L1_GATEWAY_ROUTER_PROXY_ADDR).initialize(
            notnull(L1_ETH_GATEWAY_PROXY_ADDR),
            notnull(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR)
        );
    }

    function initializeL1CustomERC20Gateway() internal {
        L1CustomERC20Gateway(L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR).initialize(
            notnull(L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL1ERC1155Gateway() internal {
        L1ERC1155Gateway(L1_ERC1155_GATEWAY_PROXY_ADDR).initialize(
            notnull(L2_ERC1155_GATEWAY_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL1ERC721Gateway() internal {
        L1ERC721Gateway(L1_ERC721_GATEWAY_PROXY_ADDR).initialize(
            notnull(L2_ERC721_GATEWAY_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL1ETHGateway() internal {
        L1ETHGateway(L1_ETH_GATEWAY_PROXY_ADDR).initialize(
            notnull(L2_ETH_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL1StandardERC20Gateway() internal {
        L1StandardERC20Gateway(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR).initialize(
            notnull(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L2_SCROLL_STANDARD_ERC20_ADDR),
            notnull(L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR)
        );
    }

    function initializeL1WETHGateway() internal {
        L1WETHGateway(payable(L1_WETH_GATEWAY_PROXY_ADDR)).initialize(
            notnull(L2_WETH_GATEWAY_PROXY_ADDR),
            notnull(L1_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR)
        );

        // set WETH gateway in router
        {
            address[] memory _tokens = new address[](1);
            _tokens[0] = notnull(L1_WETH_ADDR);
            address[] memory _gateways = new address[](1);
            _gateways[0] = notnull(L1_WETH_GATEWAY_PROXY_ADDR);
            L1GatewayRouter(L1_GATEWAY_ROUTER_PROXY_ADDR).setERC20Gateway(_tokens, _gateways);
        }
    }

    function initializeL1Whitelist() internal {
        address[] memory accounts = new address[](1);
        accounts[0] = L1_GAS_ORACLE_SENDER_ADDR;
        Whitelist(L1_WHITELIST_ADDR).updateWhitelistStatus(accounts, true);
    }

    function transferL1ContractOwnership() internal {
        Ownable(L1_ENFORCED_TX_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_ERC1155_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_ERC721_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_ETH_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_GATEWAY_ROUTER_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_MESSAGE_QUEUE_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_SCROLL_MESSENGER_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_WETH_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_GAS_PRICE_ORACLE_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_MULTIPLE_VERSION_ROLLUP_VERIFIER_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_PROXY_ADMIN_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_SCROLL_CHAIN_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L1_WHITELIST_ADDR).transferOwnership(OWNER_ADDR);
    }

    /**********************
     * L2: initialization *
     *********************/

    function initializeL2MessageQueue() internal {
        L2MessageQueue(L2_MESSAGE_QUEUE_ADDR).initialize(notnull(L2_SCROLL_MESSENGER_PROXY_ADDR));
    }

    function initializeL2TxFeeVault() internal {
        L2TxFeeVault(payable(L2_TX_FEE_VAULT_ADDR)).updateMessenger(notnull(L2_SCROLL_MESSENGER_PROXY_ADDR));
    }

    function initializeL1GasPriceOracle() internal {
        L1GasPriceOracle(L1_GAS_PRICE_ORACLE_ADDR).updateWhitelist(notnull(L2_WHITELIST_ADDR));
    }

    function initializeL2ScrollMessenger() internal {
        L2ScrollMessenger(payable(L2_SCROLL_MESSENGER_PROXY_ADDR)).initialize(notnull(L1_SCROLL_MESSENGER_PROXY_ADDR));
    }

    function initializeL2GatewayRouter() internal {
        L2GatewayRouter(L2_GATEWAY_ROUTER_PROXY_ADDR).initialize(
            notnull(L2_ETH_GATEWAY_PROXY_ADDR),
            notnull(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR)
        );
    }

    function initializeL2CustomERC20Gateway() internal {
        L2CustomERC20Gateway(L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR).initialize(
            notnull(L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL2ERC1155Gateway() internal {
        L2ERC1155Gateway(L2_ERC1155_GATEWAY_PROXY_ADDR).initialize(
            notnull(L1_ERC1155_GATEWAY_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL2ERC721Gateway() internal {
        L2ERC721Gateway(L2_ERC721_GATEWAY_PROXY_ADDR).initialize(
            notnull(L1_ERC721_GATEWAY_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL2ETHGateway() internal {
        L2ETHGateway(L2_ETH_GATEWAY_PROXY_ADDR).initialize(
            notnull(L1_ETH_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );
    }

    function initializeL2StandardERC20Gateway() internal {
        L2StandardERC20Gateway(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR).initialize(
            notnull(L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR)
        );
    }

    function initializeL2WETHGateway() internal {
        L2WETHGateway(payable(L2_WETH_GATEWAY_PROXY_ADDR)).initialize(
            notnull(L1_WETH_GATEWAY_PROXY_ADDR),
            notnull(L2_GATEWAY_ROUTER_PROXY_ADDR),
            notnull(L2_SCROLL_MESSENGER_PROXY_ADDR)
        );

        // set WETH gateway in router
        {
            address[] memory _tokens = new address[](1);
            _tokens[0] = notnull(L2_WETH_ADDR);
            address[] memory _gateways = new address[](1);
            _gateways[0] = notnull(L2_WETH_GATEWAY_PROXY_ADDR);
            L2GatewayRouter(L2_GATEWAY_ROUTER_PROXY_ADDR).setERC20Gateway(_tokens, _gateways);
        }
    }

    function initializeScrollStandardERC20Factory() internal {
        ScrollStandardERC20Factory(L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR).transferOwnership(
            notnull(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR)
        );
    }

    function initializeL2Whitelist() internal {
        address[] memory accounts = new address[](1);
        accounts[0] = L2_GAS_ORACLE_SENDER_ADDR;
        Whitelist(L2_WHITELIST_ADDR).updateWhitelistStatus(accounts, true);
    }

    function transferL2ContractOwnership() internal {
        Ownable(L1_GAS_PRICE_ORACLE_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_ERC1155_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_ERC721_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_ETH_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_GATEWAY_ROUTER_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_MESSAGE_QUEUE_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_SCROLL_MESSENGER_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_TX_FEE_VAULT_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_WETH_GATEWAY_PROXY_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_PROXY_ADMIN_ADDR).transferOwnership(OWNER_ADDR);
        Ownable(L2_WHITELIST_ADDR).transferOwnership(OWNER_ADDR);
    }
}

contract GenerateGenesisAlloc is DeterminsticDeploymentScript {
    using stdToml for string;

    /***************************
     * Configuration parameters *
     ***************************/

    // generated
    address L2_SCROLL_MESSENGER_PROXY_ADDR;

    function initConfig() private {
        // deterministically predict L2ScrollMessengerProxy address
        L2_SCROLL_MESSENGER_PROXY_ADDR = predictL2MessengerProxyAddress();
    }

    function predictL2MessengerProxyAddress() private view returns (address) {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        address L2_PROXY_ADMIN_ADDR = predict("L2_PROXY_ADMIN", type(ProxyAdminSetOwner).creationCode, args);

        address L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR = predict(
            "L2_PROXY_IMPLEMENTATION_PLACEHOLDER",
            type(EmptyContract).creationCode
        );

        bytes memory args2 = abi.encode(L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR, L2_PROXY_ADMIN_ADDR, new bytes(0));

        address predictedAddr = predict(
            "L2_SCROLL_MESSENGER_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args2
        );

        return predictedAddr;
    }

    /*************
     * Utilities *
     ************/

    /// @notice Sorts the allocs by address
    function sortJsonByKeys(string memory _path) internal {
        string[] memory commands = new string[](3);
        commands[0] = "bash";
        commands[1] = "-c";
        commands[2] = string.concat("cat <<< $(jq -S '.' ", _path, ") > ", _path);
        vm.ffi(commands);
    }

    /***************
     * Entry point *
     **************/

    function run() public {
        initConfig();

        // predeploys
        setL2MessageQueue();
        setL2GasPriceOracle();
        setL2Whitelist();
        setL2Weth();
        setL2FeeVault();

        // reset sender
        vm.resetNonce(msg.sender);

        // prefunded accounts
        setL2ScrollMessenger();
        setL2Deployer();

        // write to file
        vm.dumpState(GENESIS_ALLOC_JSON_PATH);
        sortJsonByKeys(GENESIS_ALLOC_JSON_PATH);
    }

    function setL2MessageQueue() internal {
        address predeployAddr = tryGetOverride("L2_MESSAGE_QUEUE");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        L2MessageQueue _queue = new L2MessageQueue(OWNER_ADDR);
        vm.etch(predeployAddr, address(_queue).code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000052";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_queue), _ownerSlot));

        // reset so its not included state dump
        vm.etch(address(_queue), "");
        vm.resetNonce(address(_queue));
    }

    function setL2GasPriceOracle() internal {
        address predeployAddr = tryGetOverride("L1_GAS_PRICE_ORACLE");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        L1GasPriceOracle _oracle = new L1GasPriceOracle(OWNER_ADDR);
        vm.etch(predeployAddr, address(_oracle).code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_oracle), _ownerSlot));

        // reset so its not included state dump
        vm.etch(address(_oracle), "");
        vm.resetNonce(address(_oracle));
    }

    function setL2Whitelist() internal {
        address predeployAddr = tryGetOverride("L2_WHITELIST");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        Whitelist _whitelist = new Whitelist(OWNER_ADDR);
        vm.etch(predeployAddr, address(_whitelist).code);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_whitelist), _ownerSlot));

        // reset so its not included state dump
        vm.etch(address(_whitelist), "");
        vm.resetNonce(address(_whitelist));
    }

    function setL2Weth() internal {
        address predeployAddr = tryGetOverride("L2_WETH");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        WrappedEther _weth = new WrappedEther();
        vm.etch(predeployAddr, address(_weth).code);

        // set storage
        bytes32 _nameSlot = hex"0000000000000000000000000000000000000000000000000000000000000003";
        vm.store(predeployAddr, _nameSlot, vm.load(address(_weth), _nameSlot));

        bytes32 _symbolSlot = hex"0000000000000000000000000000000000000000000000000000000000000004";
        vm.store(predeployAddr, _symbolSlot, vm.load(address(_weth), _symbolSlot));

        // reset so its not included state dump
        vm.etch(address(_weth), "");
        vm.resetNonce(address(_weth));
    }

    function setL2FeeVault() internal {
        address predeployAddr = tryGetOverride("L2_TX_FEE_VAULT");

        if (predeployAddr == address(0)) {
            return;
        }

        // set code
        L2TxFeeVault _vault = new L2TxFeeVault(OWNER_ADDR, L1_FEE_VAULT_ADDR, FEE_VAULT_MIN_WITHDRAW_AMOUNT);
        vm.etch(predeployAddr, address(_vault).code);

        vm.prank(OWNER_ADDR);
        _vault.updateMessenger(L2_SCROLL_MESSENGER_PROXY_ADDR);

        // set storage
        bytes32 _ownerSlot = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.store(predeployAddr, _ownerSlot, vm.load(address(_vault), _ownerSlot));

        bytes32 _minWithdrawAmountSlot = hex"0000000000000000000000000000000000000000000000000000000000000001";
        vm.store(predeployAddr, _minWithdrawAmountSlot, vm.load(address(_vault), _minWithdrawAmountSlot));

        bytes32 _messengerSlot = hex"0000000000000000000000000000000000000000000000000000000000000002";
        vm.store(predeployAddr, _messengerSlot, vm.load(address(_vault), _messengerSlot));

        bytes32 _recipientSlot = hex"0000000000000000000000000000000000000000000000000000000000000003";
        vm.store(predeployAddr, _recipientSlot, vm.load(address(_vault), _recipientSlot));

        // reset so its not included state dump
        vm.etch(address(_vault), "");
        vm.resetNonce(address(_vault));
    }

    function setL2ScrollMessenger() internal {
        vm.deal(L2_SCROLL_MESSENGER_PROXY_ADDR, L2_SCROLL_MESSENGER_INITIAL_BALANCE);
    }

    function setL2Deployer() internal {
        vm.deal(OWNER_ADDR, L2_DEPLOYER_INITIAL_BALANCE);
    }
}

contract GenerateGenesis is DeterminsticDeploymentScript {
    using stdToml for string;

    /***************************
     * Configuration parameters *
     ***************************/

    address L1_MESSAGE_QUEUE_PROXY_ADDR;
    address L1_SCROLL_CHAIN_PROXY_ADDR;
    address L2_TX_FEE_VAULT_ADDR;

    function initConfig() private {
        (
            L1_SCROLL_CHAIN_PROXY_ADDR,
            L1_MESSAGE_QUEUE_PROXY_ADDR
        ) = predictL1ScrollChainProxyAndL1MessageQueueProxyAddr();
        L2_TX_FEE_VAULT_ADDR = predictL2TxFeeVaultAddr();
    }

    function predictL1ScrollChainProxyAndL1MessageQueueProxyAddr() private returns (address, address) {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        address L1_PROXY_ADMIN_ADDR = predict("L1_PROXY_ADMIN", type(ProxyAdminSetOwner).creationCode, args);

        address L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR = predict(
            "L1_PROXY_IMPLEMENTATION_PLACEHOLDER",
            type(EmptyContract).creationCode
        );

        args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        address L1_SCROLL_MESSENGER_PROXY_ADDR = predict(
            "L1_SCROLL_MESSENGER_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );

        address L1_SCROLL_CHAIN_PROXY_ADDR_PREDICTED = predict(
            "L1_SCROLL_CHAIN_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );

        address L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION_ADDR = predict(
            "L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION",
            type(EnforcedTxGateway).creationCode
        );

        args = abi.encode(
            notnull(L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        address L1_ENFORCED_TX_GATEWAY_PROXY_ADDR = predict(
            "L1_ENFORCED_TX_GATEWAY_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );

        args = abi.encode(
            notnull(L1_SCROLL_MESSENGER_PROXY_ADDR),
            notnull(L1_SCROLL_CHAIN_PROXY_ADDR_PREDICTED),
            notnull(L1_ENFORCED_TX_GATEWAY_PROXY_ADDR)
        );

        address L1_MESSAGE_QUEUE_IMPLEMENTATION_ADDR = predict(
            "L1_MESSAGE_QUEUE_IMPLEMENTATION",
            type(L1MessageQueueWithGasPriceOracle).creationCode,
            args
        );

        args = abi.encode(notnull(L1_MESSAGE_QUEUE_IMPLEMENTATION_ADDR), notnull(L1_PROXY_ADMIN_ADDR), new bytes(0));

        address L1_MESSAGE_QUEUE_PROXY_ADDR_PREDICTED = predict(
            "L1_MESSAGE_QUEUE_PROXY",
            type(TransparentUpgradeableProxy).creationCode,
            args
        );

        return (L1_SCROLL_CHAIN_PROXY_ADDR_PREDICTED, L1_MESSAGE_QUEUE_PROXY_ADDR_PREDICTED);
    }

    function predictL1ScrollChainProxyAddr() private returns (address) {
        bytes memory args = abi.encode(DEPLOYER_ADDR);
        address L1_PROXY_ADMIN_ADDR = predict("L1_PROXY_ADMIN", type(ProxyAdminSetOwner).creationCode, args);

        address L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR = predict(
            "L1_PROXY_IMPLEMENTATION_PLACEHOLDER",
            type(EmptyContract).creationCode
        );

        args = abi.encode(
            notnull(L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR),
            notnull(L1_PROXY_ADMIN_ADDR),
            new bytes(0)
        );

        address predictedAddr = predict("L1_SCROLL_CHAIN_PROXY", type(TransparentUpgradeableProxy).creationCode, args);

        return predictedAddr;
    }

    function predictL2TxFeeVaultAddr() private returns (address) {
        address predeployAddr = tryGetOverride("L2_TX_FEE_VAULT");

        if (predeployAddr != address(0)) {
            return predeployAddr;
        }

        bytes memory args = abi.encode(DEPLOYER_ADDR, L1_FEE_VAULT_ADDR, FEE_VAULT_MIN_WITHDRAW_AMOUNT);
        address predictedAddr = predict("L2_TX_FEE_VAULT", type(L2TxFeeVault).creationCode, args);

        return predictedAddr;
    }

    /***************
     * Entry point *
     **************/

    function run() public {
        initConfig();

        // general config
        vm.writeJson(vm.toString(CHAIN_ID_L2), GENESIS_JSON_PATH, ".config.chainId");

        uint256 timestamp = vm.unixTime() / 1000;
        vm.writeJson(vm.toString(bytes32(timestamp)), GENESIS_JSON_PATH, ".timestamp");

        string memory extraData = string(
            abi.encodePacked(
                vm.toString(L2GETH_SIGNER_0_ADDRESS),
                "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            )
        );
        vm.writeJson(extraData, GENESIS_JSON_PATH, ".extraData");

        // scroll-specific config
        vm.writeJson(vm.toString(MAX_TX_IN_CHUNK), GENESIS_JSON_PATH, ".config.scroll.maxTxPerBlock");
        vm.writeJson(vm.toString(L2_TX_FEE_VAULT_ADDR), GENESIS_JSON_PATH, ".config.scroll.feeVaultAddress");

        vm.writeJson(vm.toString(CHAIN_ID_L1), GENESIS_JSON_PATH, ".config.scroll.l1Config.l1ChainId");
        vm.writeJson(
            vm.toString(L1_MESSAGE_QUEUE_PROXY_ADDR),
            GENESIS_JSON_PATH,
            ".config.scroll.l1Config.l1MessageQueueAddress"
        );
        vm.writeJson(
            vm.toString(L1_SCROLL_CHAIN_PROXY_ADDR),
            GENESIS_JSON_PATH,
            ".config.scroll.l1Config.scrollChainAddress"
        );

        // predeploys and prefunded accounts
        string memory alloc = vm.readFile(GENESIS_ALLOC_JSON_PATH);
        vm.writeJson(alloc, GENESIS_JSON_PATH, ".alloc");
    }
}
