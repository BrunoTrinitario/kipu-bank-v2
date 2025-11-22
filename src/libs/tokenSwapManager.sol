// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { Commands } from "lib/universal-router/contracts/libraries/Commands.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenSwapManager
/// @notice Módulo simple para swappear tokens y ETH a USDC usando Universal Router (Uniswap v4)
/// @dev Mantiene la interfaz pública original: swapTokenForUSDC y swapETHForUSDC
contract TokenSwapManager {
    using SafeERC20 for IERC20;

    IUniversalRouter public immutable universalRouter;
    address public immutable usdc; // token de contabilidad interna (USDC)

    error ZeroDeposit();
    error SwapFailed();

    /// @notice slippage expresado en basis points (10000 = 100%)
    uint16 public immutable slippageBps;

    /// @param _universalRouter Dirección del Universal Router (Uniswap v4)
    /// @param _usdc Dirección del token USDC
    /// @param _slippageBps Slippage permitido en basis points (por ejemplo 100 = 1%)
    constructor(address _usdc,address payable _universalRouter ,uint16 _slippageBps) {
        require(_universalRouter != address(0) && _usdc != address(0), "invalid params");
        universalRouter = IUniversalRouter(_universalRouter);
        usdc = _usdc;
        slippageBps = _slippageBps;
    }

    /// @notice Swapea un token ERC20 a USDC usando Universal Router
    /// @dev El contrato llamante debe haber transferido previamente el token a este contrato
    ///      o, más típico, KipuBank mantiene los fondos y es quien llama a esta función.
    function swapTokenForUSDC(address token, uint256 amount) public returns (uint256) {
        if (amount == 0) revert ZeroDeposit();

        // Aprobamos al router para mover los tokens desde este contrato
        IERC20(token).safeIncreaseAllowance(address(universalRouter), amount);

        uint256 beforeBal = IERC20(usdc).balanceOf(address(this));

        // Comando EXACT_INPUT_SINGLE (V3 swap exact in)
        bytes memory commands = abi.encodePacked(Commands.V3_SWAP_EXACT_IN);

        // inputs debe ser un array de bytes, no un bytes plano
        bytes[] memory inputs = new bytes[](1);

        // Estructura del input para V3 swap exact in:
        // tokenIn, tokenOut, amountIn, minAmountOut, recipient
        uint256 minAmountOut = 0;
        inputs[0] = abi.encode(
            token,
            usdc,
            amount,
            minAmountOut,
            address(this)
        );

        // Llamada correcta: execute(bytes, bytes[], uint256)
        universalRouter.execute(
            commands,
            inputs,
            block.timestamp   // deadline
        );

        uint256 afterBal = IERC20(usdc).balanceOf(address(this));
        uint256 received = afterBal - beforeBal;

        if (received == 0) revert SwapFailed();

        // Enviamos los USDC al caller (KipuBank)
        IERC20(usdc).safeTransfer(msg.sender, received);

        return received;
    }
    /// @notice Swapea ETH nativo (msg.value) a USDC usando Universal Router
    /// @dev La versión exacta del comando para ETH puede requerir usar WETH interno;
    ///      aquí usamos el mismo EXACT_INPUT_SINGLE con un placeholder para WETH.
    function swapETHForUSDC(uint256 amountIn) public payable returns (uint256) {
        if (amountIn == 0 || msg.value != amountIn) revert ZeroDeposit();

        uint256 beforeBal = IERC20(usdc).balanceOf(address(this));

        bytes memory commands = abi.encodePacked(Commands.V3_SWAP_EXACT_IN);

        // inputs debe ser bytes[]
        bytes[] memory inputs = new bytes[](1);

        address wethPlaceholder = address(0);
        uint256 minAmountOut = 0;

        // asignar al array
        inputs[0] = abi.encode(
            wethPlaceholder,
            usdc,
            amountIn,
            minAmountOut,
            address(this)
        );

        // execute necesita 3 parámetros
        universalRouter.execute{value: amountIn}(
            commands,
            inputs,
            block.timestamp
        );

        uint256 afterBal = IERC20(usdc).balanceOf(address(this));
        uint256 received = afterBal - beforeBal;

        if (received == 0) revert SwapFailed();

        return received;
    }
}

