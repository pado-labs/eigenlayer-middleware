// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "eigenlayer-contracts/script/middleware/DeployOpenEigenLayer.s.sol";

import "eigenlayer-contracts/src/contracts/permissions/PauserRegistry.sol";
import "eigenlayer-contracts/src/test/mocks/EmptyContract.sol";

import "src/BLSPublicKeyCompendium.sol";
import "src/BLSRegistryCoordinatorWithIndices.sol";
import "src/BLSPubkeyRegistry.sol";
import "src/IndexRegistry.sol";
import "src/StakeRegistry.sol";
import "src/BLSOperatorStateRetriever.sol";

import "forge-std/Test.sol";
import "test/mocks/ServiceManagerMock.sol";

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

// TODO: REVIEW AND FIX THIS ENTIRE SCRIPT

// # To load the variables in the .env file
// source .env

// # To deploy and verify our contract
// forge script script/Deployer.s.sol:EigenDADeployer --rpc-url $RPC_URL  --private-key $PRIVATE_KEY --broadcast -vvvv
contract MiddlewareDeployer is DeployOpenEigenLayer {
    ServiceManagerMock public mockServiceManager;
    ProxyAdmin public proxyAdmin;
    PauserRegistry public pauserRegistry;

    BLSPublicKeyCompendium public pubkeyCompendium;
    BLSRegistryCoordinatorWithIndices public registryCoordinator;
    IBLSPubkeyRegistry public blsPubkeyRegistry;
    IIndexRegistry public indexRegistry;
    IStakeRegistry public stakeRegistry;
    BLSOperatorStateRetriever public blsOperatorStateRetriever;

    IBLSRegistryCoordinatorWithIndices public registryCoordinatorImplementation;
    IBLSPubkeyRegistry public blsPubkeyRegistryImplementation;
    IIndexRegistry public indexRegistryImplementation;
    IStakeRegistry public stakeRegistryImplementation;

    string deployConfigPath = "script/eigenda_deploy_config.json";

    struct AddressConfig {
        address eigenLayerCommunityMultisig;
        address eigenLayerOperationsMultisig;
        address eigenLayerPauserMultisig;
        address communityMultiSig;
        address pauser;
        address churner;
        address ejector;
    }
    
    function _deployEigenLayerContracts(
        AddressConfig memory addressConfig,
        uint8 numStrategies,
        uint256 initialSupply,
        address tokenOwner,
        uint256 maxOperatorCount
    ) internal {
        StrategyConfig[] memory strategyConfigs = new StrategyConfig[](numStrategies);
        // deploy a token and create a strategy config for each token
        for (uint8 i = 0; i < numStrategies; i++) {
            address tokenAddress = address(new ERC20PresetFixedSupply(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TOK", i)), initialSupply, tokenOwner));
            strategyConfigs[i] = StrategyConfig({
                maxDeposits: type(uint256).max,
                maxPerDeposit: type(uint256).max,
                tokenAddress: tokenAddress,
                tokenSymbol: string(abi.encodePacked("TOK", i))
            });
        }

        _deployEigenLayer(addressConfig.eigenLayerCommunityMultisig, addressConfig.eigenLayerOperationsMultisig, addressConfig.eigenLayerPauserMultisig, strategyConfigs);

        // deploy proxy admin for ability to upgrade proxy contracts
        proxyAdmin = new ProxyAdmin();

        // deploy pauser registry
        {
            address[] memory pausers = new address[](2);
            pausers[0] = addressConfig.pauser;
            pausers[1] = addressConfig.communityMultiSig;
            pauserRegistry = new PauserRegistry(pausers, addressConfig.communityMultiSig);
        }

        emptyContract = new EmptyContract();

        // hard-coded inputs

        /**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        pubkeyCompendium = new BLSPublicKeyCompendium();
        registryCoordinator = BLSRegistryCoordinatorWithIndices(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(proxyAdmin), ""))
        );
        blsPubkeyRegistry = IBLSPubkeyRegistry(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(proxyAdmin), ""))
        );
        indexRegistry = IIndexRegistry(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(proxyAdmin), ""))
        );
        stakeRegistry = IStakeRegistry(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(proxyAdmin), ""))
        );

        mockServiceManager = new ServiceManagerMock(slasher);

        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        {
            stakeRegistryImplementation = new StakeRegistry(
                registryCoordinator,
                strategyManager,
                IServiceManager(address(mockServiceManager))
            );

            // set up a quorum with each strategy that needs to be set up
            uint96[] memory minimumStakeForQuourm = new uint96[](numStrategies);
            IVoteWeigher.StrategyAndWeightingMultiplier[][] memory strategyAndWeightingMultipliers = new IVoteWeigher.StrategyAndWeightingMultiplier[][](numStrategies);
            for (uint i = 0; i < numStrategies; i++) {
                strategyAndWeightingMultipliers[i] = new IVoteWeigher.StrategyAndWeightingMultiplier[](1);
                strategyAndWeightingMultipliers[i][0] = IVoteWeigher.StrategyAndWeightingMultiplier({
                    strategy: deployedStrategyArray[i],
                    multiplier: 1 ether
                });
            }

            proxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(payable(address(stakeRegistry))),
                address(stakeRegistryImplementation),
                abi.encodeWithSelector(
                    StakeRegistry.initialize.selector,
                    minimumStakeForQuourm,
                    strategyAndWeightingMultipliers
                )
            );
        }

        registryCoordinatorImplementation = new BLSRegistryCoordinatorWithIndices(
            slasher,
            IServiceManager(address(mockServiceManager)),
            stakeRegistry,
            blsPubkeyRegistry,
            indexRegistry
        );
        
        {
            IBLSRegistryCoordinatorWithIndices.OperatorSetParam[] memory operatorSetParams = new IBLSRegistryCoordinatorWithIndices.OperatorSetParam[](numStrategies);
            for (uint i = 0; i < numStrategies; i++) {
                // hard code these for now
                operatorSetParams[i] = IBLSRegistryCoordinatorWithIndices.OperatorSetParam({
                    maxOperatorCount: uint32(maxOperatorCount),
                    kickBIPsOfOperatorStake: 11000, // an operator needs to have kickBIPsOfOperatorStake / 10000 times the stake of the operator with the least stake to kick them out
                    kickBIPsOfTotalStake: 1001 // an operator needs to have less than kickBIPsOfTotalStake / 10000 of the total stake to be kicked out
                });
            }
            proxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(payable(address(registryCoordinator))),
                address(registryCoordinatorImplementation),
                abi.encodeWithSelector(
                    BLSRegistryCoordinatorWithIndices.initialize.selector,
                    addressConfig.churner,
                    addressConfig.ejector,
                    operatorSetParams,
                    IPauserRegistry(address(pauserRegistry)),
                    0 // initial paused status is nothing paused
                )
            );
        }

        blsPubkeyRegistryImplementation = new BLSPubkeyRegistry(
            registryCoordinator,
            pubkeyCompendium
        );

        proxyAdmin.upgrade(
            TransparentUpgradeableProxy(payable(address(blsPubkeyRegistry))),
            address(blsPubkeyRegistryImplementation)
        );

        indexRegistryImplementation = new IndexRegistry(
            registryCoordinator
        );

        proxyAdmin.upgrade(
            TransparentUpgradeableProxy(payable(address(indexRegistry))),
            address(indexRegistryImplementation)
        );

        blsOperatorStateRetriever = new BLSOperatorStateRetriever();
    }

    function run() external {
        

        // READ JSON CONFIG DATA
        string memory config_data = vm.readFile(deployConfigPath);

        
        uint8 numStrategies = uint8(stdJson.readUint(config_data, ".numStrategies"));
        {
            AddressConfig memory addressConfig;
            addressConfig.eigenLayerCommunityMultisig = msg.sender;
            addressConfig.eigenLayerOperationsMultisig = msg.sender;
            addressConfig.eigenLayerPauserMultisig = msg.sender;
            addressConfig.communityMultiSig = msg.sender;
            addressConfig.pauser = msg.sender;
            addressConfig.churner = msg.sender;
            addressConfig.ejector = msg.sender;

            uint256 initialSupply = 1000 ether;
            address tokenOwner = msg.sender;
            uint256 maxOperatorCount = 3;
            // bytes memory parsedData = vm.parseJson(config_data);
            bool useDefaults = stdJson.readBool(config_data, ".useDefaults");
            if(!useDefaults) {
                addressConfig.eigenLayerCommunityMultisig = stdJson.readAddress(config_data, ".eigenLayerCommunityMultisig");
                addressConfig.eigenLayerOperationsMultisig = stdJson.readAddress(config_data, ".eigenLayerOperationsMultisig");
                addressConfig.eigenLayerPauserMultisig = stdJson.readAddress(config_data, ".eigenLayerPauserMultisig");
                addressConfig.communityMultiSig = stdJson.readAddress(config_data, ".communityMultisig");
                addressConfig.pauser = stdJson.readAddress(config_data, ".pauser");
                addressConfig.churner = stdJson.readAddress(config_data, ".churner");
                addressConfig.ejector = stdJson.readAddress(config_data, ".ejector");

                initialSupply = stdJson.readUint(config_data, ".initialSupply");
                tokenOwner = stdJson.readAddress(config_data, ".tokenOwner");
                maxOperatorCount = stdJson.readUint(config_data, ".maxOperatorCount");
            }


            vm.startBroadcast();

            _deployEigenLayerContracts(
                addressConfig,
                numStrategies,
                initialSupply,
                tokenOwner,
                maxOperatorCount
            );

            vm.stopBroadcast();
        }

        uint256[] memory stakerPrivateKeys = stdJson.readUintArray(config_data, ".stakerPrivateKeys");
        address[] memory stakers = new address[](stakerPrivateKeys.length);
        for (uint i = 0; i < stakers.length; i++) {
            stakers[i] = vm.addr(stakerPrivateKeys[i]);
        }
        uint256[] memory stakerETHAmounts = new uint256[](stakers.length);
        // 0.1 eth each
        for (uint i = 0; i < stakerETHAmounts.length; i++) {
            stakerETHAmounts[i] = 0.1 ether;
        }

        // stakerTokenAmount[i][j] is the amount of token i that staker j will receive
        bytes memory stakerTokenAmountsRaw = stdJson.parseRaw(config_data, ".stakerTokenAmounts");
        uint256[][] memory stakerTokenAmounts = abi.decode(stakerTokenAmountsRaw, (uint256[][]));

        uint256[] memory operatorPrivateKeys = stdJson.readUintArray(config_data, ".operatorPrivateKeys");
        address[] memory operators = new address[](operatorPrivateKeys.length);
        for (uint i = 0; i < operators.length; i++) {
            operators[i] = vm.addr(operatorPrivateKeys[i]);
        }
        uint256[] memory operatorETHAmounts = new uint256[](operators.length);
        // 5 eth each
        for (uint i = 0; i < operatorETHAmounts.length; i++) {
            operatorETHAmounts[i] = 5 ether;
        }

        vm.startBroadcast();

        // Allocate eth to stakers and operators
        _allocate(
            IERC20(address(0)),
            stakers,
            stakerETHAmounts
        );

        _allocate(
            IERC20(address(0)),
            operators,
            operatorETHAmounts
        );

        // Allocate tokens to stakers
        for (uint8 i = 0; i < numStrategies; i++) {
            _allocate(
                IERC20(deployedStrategyArray[i].underlyingToken()),
                stakers,
                stakerTokenAmounts[i]
            );
        }

        {
            IStrategy[] memory strategies = new IStrategy[](numStrategies);
            for (uint8 i = 0; i < numStrategies; i++) {
                strategies[i] = deployedStrategyArray[i];
            }
            strategyManager.addStrategiesToDepositWhitelist(strategies);
        }

        vm.stopBroadcast();

        // Register operators with EigenLayer
        for (uint256 i = 0; i < operatorPrivateKeys.length; i++) {
            vm.broadcast(operatorPrivateKeys[i]);
            address earningsReceiver = address(uint160(uint256(keccak256(abi.encodePacked(operatorPrivateKeys[i])))));
            address delegationApprover = address(0); //address(uint160(uint256(keccak256(abi.encodePacked(earningsReceiver)))));
            uint32 stakerOptOutWindowBlocks = 100;
            string memory metadataURI = string.concat("https://urmom.com/operator/", vm.toString(i));
            delegation.registerAsOperator(IDelegationManager.OperatorDetails(earningsReceiver, delegationApprover, stakerOptOutWindowBlocks), metadataURI);
        }

        // Deposit stakers into EigenLayer and delegate to operators
        for (uint256 i = 0; i < stakerPrivateKeys.length; i++) {
            vm.startBroadcast(stakerPrivateKeys[i]);
            for (uint j = 0; j < numStrategies; j++) {
                if(stakerTokenAmounts[j][i] > 0) {
                    deployedStrategyArray[j].underlyingToken().approve(address(strategyManager), stakerTokenAmounts[j][i]);
                    strategyManager.depositIntoStrategy(
                        deployedStrategyArray[j],
                        deployedStrategyArray[j].underlyingToken(),
                        stakerTokenAmounts[j][i]
                    );
                }
            }
            IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry;
            delegation.delegateTo(operators[i], approverSignatureAndExpiry, bytes32(0));
            vm.stopBroadcast();
        }

        string memory output = "eigenDA deployment output";
        vm.serializeAddress(output, "mockServiceManager", address(mockServiceManager));
        vm.serializeAddress(output, "blsOperatorStateRetriever", address(blsOperatorStateRetriever));
        vm.serializeAddress(output, "pubkeyCompendium", address(pubkeyCompendium));
        vm.serializeAddress(output, "blsPubkeyRegistry", address(blsPubkeyRegistry));
        vm.serializeAddress(output, "blsRegistryCoordinatorWithIndices", address(registryCoordinator));

        string memory finalJson = vm.serializeString(output, "object", output);

        vm.createDir("./script/output", true);
        vm.writeJson(finalJson, "./script/output/eigenda_deploy_output.json");        
    }
   function _allocate(IERC20 token, address[] memory tos, uint256[] memory amounts) internal {
        for (uint256 i = 0; i < tos.length; i++) {
            if(token == IERC20(address(0))) {
                payable(tos[i]).transfer(amounts[i]);
            } else {
                token.transfer(tos[i], amounts[i]);
            }
        }
    }
}
