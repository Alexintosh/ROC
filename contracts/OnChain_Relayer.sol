pragma solidity ^0.4.17;

import "./WETH9.sol";
import "./Interface0x.sol";
import "./TokenTransferProxy.sol";
import "./SafeMath.sol"; 

contract OnChain_Relayer is SafeMath{


    struct SpecificOrder {
        int amount;
        uint price;
        address maker;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    mapping(bytes32 => SpecificOrder) order_details;
    mapping(bytes32 => uint) order_index;
    bytes32[] public orders;
    address public owner;
    address public zeroX_address;
    address public token_address;
    address public wrapped_ether_address;
    address public token_transfer_proxy_address;
    Interface0x zeroX;
    Token ERC20Token;
    WETH9 Wrapped_Ether;
    TokenTransferProxy TTP;

    modifier onlyOwner() {require(msg.sender == owner);_;}

    event NewOrder(bytes32 _hash,int _amount,uint _price);
    event FilledOrder(bytes32 _hash, uint _amount, uint _price);
    event CancelledOrder(bytes32 _hash,int _amount,uint _price);    

    function OnChain_Relayer() public {
        owner = msg.sender;
        orders.push(0);
    }


    function placeLimit(int _amount, uint _price,uint8 _v,bytes32 _r,bytes32 _s) payable public returns(bytes32 _orderHash){
        require(_amount !=0);

        if(_amount > 0){
            require(safeMul(abs(_amount),_price) == msg.value);
            Wrapped_Ether.delegatecall(bytes4(sha3("deposit(uint256)")), msg.value);
            Wrapped_Ether.delegatecall(bytes4(sha3("approve(address,uint256)")),zeroX_address, msg.value);
            require(Wrapped_Ether.allowance(msg.sender,zeroX_address) == msg.value);
        }
        else{
            require(msg.value == 0);
            ERC20Token.delegatecall(bytes4(sha3("approve(address,uint256)")),zeroX_address,msg.value);
            require(ERC20Token.allowance(msg.sender,zeroX_address) == msg.value);
        }
        uint nonce = safeMul(_v,block.timestamp) % now;
        bytes32 hash = keccak256(msg.sender,_amount,_price,now,nonce);
        order_details[hash].amount = _amount;
        order_details[hash].price = _price;
        order_details[hash].maker= msg.sender;
        order_details[hash].v= _v;
        order_details[hash].r= _r;
        order_details[hash].s= _s;
        orders.push(hash);
        NewOrder(hash,_amount,_price);
    }

    function cancelLimit(bytes32 _orderHash) public returns(bool success){
        removeOrder(_orderHash);
        int _amount; uint _price; address _maker;
        (_amount,_price,_maker) = getInfo(_orderHash);
        require(msg.sender == _maker);
        uint8 _v;bytes32 _r; bytes32 _s;
        (_v,_r,_s) = getSignature(_orderHash);
        address[5] memory orderAddresses;
        uint[6] memory orderValues;
        uint salt = safeMul(safeMul(now,block.timestamp),safeMul(abs(_amount),_price)) % _v;
        if(_amount > 0){
            orderAddresses = [_maker,msg.sender,wrapped_ether_address,token_address,owner];
            orderValues = [safeMul(abs(_amount),_price),abs(_amount),0,0,2**256 - 1,salt];
        }
        else {
            orderAddresses = [_maker,msg.sender,token_address,wrapped_ether_address,owner];
            orderValues = [abs(_amount),safeMul(abs(_amount),_price),0,0,2**256 - 1,salt];
        }
        assert(zeroX.cancelOrder(orderAddresses,orderValues,abs(_amount)) >0);
        CancelledOrder(_orderHash,_amount,_price);
        return true;

    }

    function takeOrder(bytes32 _orderHash, uint _TokenAmount) payable public returns(bool _success){
        int _amount; uint _price; address _maker;
        (_amount,_price,_maker) = getInfo(_orderHash);
        require(abs(_amount) >= _TokenAmount);
        uint8 _v;bytes32[] sig;
        (_v,sig[0],sig[1]) = getSignature(_orderHash);
        address[5] memory orderAddresses;
        uint[6] memory orderValues;
        uint salt = safeMul(safeMul(now,block.timestamp),safeMul(abs(_amount),_price)) % _v;
        if(_amount > 0){
            require(msg.value == 0);
            orderAddresses = [_maker,msg.sender,wrapped_ether_address,token_address,owner];
            orderValues = [safeMul(_TokenAmount,_price),_TokenAmount,0,0,2**256 - 1,salt];
            ERC20Token.delegatecall(bytes4(sha3("approve(address,uint256)")),zeroX_address,msg.value);
            require(ERC20Token.allowance(msg.sender,zeroX_address) == msg.value);
        }
        else {
            require(safeMul(_TokenAmount,_price) == msg.value);
            Wrapped_Ether.delegatecall(bytes4(sha3("deposit(uint256)")), msg.value);
            Wrapped_Ether.delegatecall(bytes4(sha3("approve(address,uint256)")),zeroX_address, msg.value);
            require(Wrapped_Ether.allowance(msg.sender,zeroX_address) == msg.value);
            orderAddresses = [_maker,msg.sender,token_address,wrapped_ether_address,owner];
            orderValues = [_TokenAmount,safeMul(_TokenAmount,_price),0,0,2**256 - 1,salt];
        }

        //zeroX.fillOrder(orderAddresses,orderValues,uint fillTakerTokenAmount,bool shouldThrowOnInsufficientBalanceOrAllowance, uint8 v,bytes32 r, bytes32 s);
        uint _taken = zeroX.fillOrder(orderAddresses,orderValues,_TokenAmount,false,_v,sig[0],sig[1]);
     if(_taken > 0){
        if(_taken == abs(_amount)){
            removeOrder(_orderHash);
        }
        else{
            order_details[_orderHash].amount = order_details[_orderHash].amount - int(_TokenAmount);
        }
        FilledOrder(_orderHash,_TokenAmount,_price);
        return true;
     }
     else{
        cancelLimit(_orderHash);
        return false ;
     }
    }

    function getInfo(bytes32 _hash)constant public returns(int _amount, uint _price, address _maker){
        return(order_details[_hash].amount,order_details[_hash].price,order_details[_hash].maker);
    }

    function getSignature(bytes32 _hash) constant internal returns(uint8 _v,bytes32 _r, bytes32 _s){
        return(order_details[_hash].v,order_details[_hash].r,order_details[_hash].s);
    }

    function setToken(address _tokenAddress) public onlyOwner() {
        token_address = _tokenAddress;
        ERC20Token = Token(token_address);
    }

    function setWrappedEther(address _tokenAddress) public onlyOwner() {
        wrapped_ether_address = _tokenAddress;
        Wrapped_Ether = WETH9(wrapped_ether_address);
    }

    function set0x_address(address _0x) public onlyOwner(){
        zeroX_address = _0x;
        zeroX = Interface0x(_0x);
    }

    function setTokenTransferProxy(address _ttp) public onlyOwner(){
        token_transfer_proxy_address = _ttp;
        TTP = TokenTransferProxy(_ttp);
    }

    function setOwner(address _newOwner) public onlyOwner(){
        owner = _newOwner;
    }


    function removeOrder(bytes32 _remove) internal {
    uint last_index = orders.length;
    bytes32 last_hash = orders[last_index];
    //If the hash we want to remove is the final hash in array
    if (last_hash != _remove) {
      uint remove_index = order_index[_remove];
      //Update the order index of the last hash to that of the removed hash index
      order_index[last_hash] = remove_index;
      //Set the order of the removed index to the order of the last hash
      orders[remove_index] = orders[last_index];
    }
    //Remove the order index for this address
    delete order_index[_remove];
    //Finally, decrement the order balances length
    orders.length = safeSub(orders.length,1);
  }
}