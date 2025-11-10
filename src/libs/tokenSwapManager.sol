// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/v2-periphery/contracts/UniswapV2Router02.sol";
import "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
contract tokenSwapManager {
    IUniswapV2Router02 public router;
    using SafeERC20 for IERC20;
    address public usdc;
    error notPairable();
    error ZeroDeposit();
    error swapFailed();
    uint1616 slippage;

    //Seteamos el token uniswap para hacer los swap de tokens
    //Setemaos el adress del token USDC estable
    constructor(address _router, address _usdc, uint16 percentaje) {
        router = IUniswapV2Router02(_router);
        usdc = _usdc;
        slippage = 10*percentaje;
    }

    /**
     * @notice Swapea un token ERC20 a USDC.
     * @dev El contrato llamante debe haber transferido previamente el token a este módulo.
     */
    function swapTokenForUSDC(address token, uint256 amount) external returns (uint256) {
        //Buscamos el par token a USDC si no lo encunetra o no existe devuelve la adress de ETH
        address pair = IUniswapV2Factory(router.factory()).getPair(token, usdc);
        if (pair == address(0)) {
            // Si no hay par, devolvemos los tokens al usuario
            IERC20(token).transfer(msg.sender, amount);
            revert NotPairable();
        }
        //Setean los permisos para que uniswap tome los ERC20.
        IERC20(token).approve(address(router), amount);

        //tomamos las adress que vamos a utilizar para hacer el swap
        address ;
        path[0] = token;
        path[1] = usdc;

        //guardamos el balance previo antes de hacer el swap
        uint256 beforeBal = IERC20(usdc).balanceOf(address(this));

        //ejecutamos el swap
        router.swapExactTokensForTokens(
            amount,
            slippage,
            path,
            address(this),
            block.timestamp
        );
        //calculamos lo recibido luego del swap
        uint256 afterBal = IERC20(usdc).balanceOf(address(this));
        uint256 received = afterBal - beforeBal;

        // Enviar los USDC al contrato principal
        IERC20(usdc).transfer(msg.sender, received);
        return received;
    }

    /**
     * @notice Swapea ETH a USDC.
     */
    function swapETHForUSDC() external payable returns (uint256) {
       require(amountIn > 0, zeroDeposit());

        address ;
        path[0] = router.WETH(); // WETH (entrada)
        path[1] = usdc;          // USDC (salida)

        uint256 beforeBal = IERC20(usdc).balanceOf(address(this));

        // Hacemos el swap del ETH nativo a USDC (el contrato recibe los tokens)
        router.swapExactETHForTokens{value: amountIn}(
            slippage,              // cantidad mínima de salida (puedes mejorar con slippage)
            path,
            address(this),  // el receptor es el contrato, NO el usuario
            block.timestamp
        );

        uint256 afterBal = IERC20(usdc).balanceOf(address(this));
        uint256 received = afterBal - beforeBal;

        require(received > 0, swapFailed());

        return received; // devolvemos cuántos USDC recibió el contrato
    }
}
