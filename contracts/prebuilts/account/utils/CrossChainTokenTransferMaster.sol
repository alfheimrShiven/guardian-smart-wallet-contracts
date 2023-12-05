// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;
// Account Abstraction setup for smart wallets.
import { EntryPoint, IEntryPoint } from "contracts/prebuilts/account/utils/Entrypoint.sol";
import { UserOperation } from "contracts/prebuilts/account/utils/UserOperation.sol";

// Target
import { IAccountPermissions } from "contracts/extension/interface/IAccountPermissions.sol";
import { AccountFactory } from "contracts/prebuilts/account/non-upgradeable/AccountFactory.sol";
import { Account as SimpleAccount } from "contracts/prebuilts/account/non-upgradeable/Account.sol";

import { IERC20 } from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/token/ERC20/IERC20.sol";

contract CrossChainTokenTransferMaster {
    // Target contracts
    EntryPoint private entrypoint;
    address payable private beneficiary = payable(address(0x45654));

    function _prepareSignature(
        IAccountPermissions.SignerPermissionRequest memory _req
    ) internal view returns (bytes32 typedDataHash) {
        bytes32 typehashSignerPermissionRequest = keccak256(
            "SignerPermissionRequest(address signer,uint8 isAdmin,address[] approvedTargets,uint256 nativeTokenLimitPerTransaction,uint128 permissionStartTimestamp,uint128 permissionEndTimestamp,uint128 reqValidityStartTimestamp,uint128 reqValidityEndTimestamp,bytes32 uid)"
        );
        bytes32 nameHash = keccak256(bytes("Account"));
        bytes32 versionHash = keccak256(bytes("1"));
        bytes32 typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, sender));

        bytes memory encodedRequestStart = abi.encode(
            typehashSignerPermissionRequest,
            _req.signer,
            _req.isAdmin,
            keccak256(abi.encodePacked(_req.approvedTargets)),
            _req.nativeTokenLimitPerTransaction
        );

        bytes memory encodedRequestEnd = abi.encode(
            _req.permissionStartTimestamp,
            _req.permissionEndTimestamp,
            _req.reqValidityStartTimestamp,
            _req.reqValidityEndTimestamp,
            _req.uid
        );

        bytes32 structHash = keccak256(bytes.concat(encodedRequestStart, encodedRequestEnd));
        typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _setupUserOp(
        uint256 _signerPKey,
        bytes memory _initCode,
        bytes memory _callDataForEntrypoint,
        address _sender
    ) internal returns (UserOperation[] memory ops) {
        uint256 nonce = entrypoint.getNonce(_sender, 0);

        // Get user op fields
        UserOperation memory op = UserOperation({
            sender: _sender,
            nonce: nonce,
            initCode: _initCode,
            callData: _callDataForEntrypoint,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 500_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        // Sign UserOp
        bytes32 opHash = EntryPoint(entrypoint).getUserOpHash(op);
        bytes32 msgHash = ECDSA.toEthSignedMessageHash(opHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPKey, msgHash);
        bytes memory userOpSignature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(msgHash, v, r, s);
        address expectedSigner = vm.addr(_signerPKey);

        op.signature = userOpSignature;

        // Store UserOp
        ops = new UserOperation[](1);
        ops[0] = op;
    }

    function _setupUserOpExecute(
        uint256 _signerPKey,
        bytes memory _initCode,
        address _target,
        uint256 _value,
        bytes memory _callData,
        address _sender
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            _target,
            _value,
            _callData
        );

        return _setupUserOp(_signerPKey, _initCode, callDataForEntrypoint, _sender);
    }

    function _setupUserOpExecuteBatch(
        uint256 _signerPKey,
        bytes memory _initCode,
        address[] memory _target,
        uint256[] memory _value,
        bytes[] memory _callData,
        address _sender
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            _target,
            _value,
            _callData
        );

        return _setupUserOp(_signerPKey, _initCode, callDataForEntrypoint, _sender);
    }

    /*///////////////////////////////////////////////////////////////
                    Test: performing a contract call
    //////////////////////////////////////////////////////////////*/

    /// @dev Perform many state changing transactions in a batch via Entrypoint.
    function _initiateTokenTransferWithLink(
        address _smartWalletAccount,
        address _ccip,
        address _link,
        address _token,
        uint64 _destinationChainSelector,
        address _receiver,
        uint _tokenAmount,
        uint _linkAmount
    ) public {
        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        targets[0] = _link;
        values[0] = 0;
        callData[0] = abi.encodeWithSignature("approve(address, uint)", _ccip, _linkAmount);

        targets[1] = _token;
        values[1] = 0;
        callData[1] = abi.encodeWithSignature("approve(address, uint)", _ccip, _tokenAmount);

        targets[2] = _ccip;
        values[2] = 0;
        callData[2] = abi.encodeWithSignature(
            "transferTokensPayLINK(uint64 , address , address , address ,uint256 , uint256,   uint256 )",
            _destinationChainSelector,
            _receiver,
            _smartWalletAccount,
            _token,
            _tokenAmount,
            _linkAmount,
            _tokenAmount
        );

        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            accountAdminPKey,
            bytes(""),
            targets,
            values,
            callData,
            _smartWalletAccount
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    function _initiateTokenTransferWithNativeToken(
        address _smartWalletAccount,
        address _ccip,
        address _token,
        uint64 _destinationChainSelector,
        address _receiver,
        uint _tokenAmount,
        uint _estimatedAmount
    ) public {
        uint256 count = 2;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        targets[0] = _token;
        values[0] = 0;
        callData[0] = abi.encodeWithSignature("approve(address, uint)", _ccip, _tokenAmount);

        targets[1] = _ccip;
        values[1] = _estimatedAmount;
        callData[1] = abi.encodeWithSignature(
            "transferTokensPayNative( uint64 ,  address ,  address , address,  uint256 , uint256   )",
            _destinationChainSelector,
            _receiver,
            _smartWalletAccount,
            _token,
            _tokenAmount,
            _tokenAmount
        );
        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            accountAdminPKey,
            bytes(""),
            targets,
            values,
            callData,
            _smartWalletAccount
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }
}
