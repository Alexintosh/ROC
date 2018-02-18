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
        uint salt;
    }

    mapping(bytes32 => SpecificOrder) order_details;
    mapping(bytes32 => uint) order_index;
    bytes32[] public orders;
    address public owner;
    address public zeroX_address;
    address public token_address;
    address public wrapped_ether_address;
    address public tokentransferproxy_address;
    Interface0x zeroX;
    Token ERC20Token;
    WETH9 Wrapped_Ether;

    modifier onlyOwner() {require(msg.sender == owner);_;}

    event NewOrder(bytes32 _hash,int _amount,uint _price);
    event FilledOrder(bytes32 _hash, uint _amount, uint _price);
    event CancelledOrder(bytes32 _hash,int _amount,uint _price); 
    event Print(string _blah, uint _val);
    event Print2(string _b,int _val);   

    function OnChain_Relayer() public {
        owner = msg.sender;
        orders.push(0);
    }


    function placeLimit(int _amount, uint _price,bytes32 hash,uint _salt,uint8 _v,bytes32 _r,bytes32 _s) public{
        require(_amount !=0);
        if(_amount > 0){
            assert(Wrapped_Ether.allowance(msg.sender,tokentransferproxy_address) == safeMul(uint(_amount),_price));
        }
        else{
            assert(ERC20Token.allowance(msg.sender,tokentransferproxy_address) == uint(-_amount));
        }
        order_details[hash].amount = _amount;
        order_details[hash].price = _price;
        order_details[hash].maker= msg.sender;
        order_details[hash].v= _v;
        order_details[hash].r= _r;
        order_details[hash].s= _s;
        order_details[hash].salt = _salt;
        orders.push(hash);
        order_index[hash] = orders.length;
        NewOrder(hash,_amount,_price);
    }

    function cancelLimit(bytes32 _orderHash) public returns(bool success){
        removeOrder(_orderHash);
        int _amount; uint _price; address _maker;
        (_amount,_price,_maker) = getInfo(_orderHash);
        require(msg.sender == _maker);
        uint8 _v;bytes32[2] memory sig;uint salt;
        (_v,sig[0],sig[1],salt) = getSignature(_orderHash);
        address[5] memory orderAddresses;
        uint value;
        uint[6] memory orderValues;
        if(_amount > 0){
            value = uint(_amount);
            orderAddresses = [_maker,msg.sender,wrapped_ether_address,token_address,owner];
            orderValues = [safeMul(uint(_amount),_price),uint(_amount),0,0,2**256 - 1,salt];
        }
        else {
            value = uint(-_amount);
            orderAddresses = [_maker,msg.sender,token_address,wrapped_ether_address,owner];
            orderValues = [value,safeMul(uint(-_amount),_price),0,0,2**256 - 1,salt];
        }
        assert(zeroX.cancelOrder(orderAddresses,orderValues,value) >0);
        CancelledOrder(_orderHash,_amount,_price);
        return true;

    }

    function takeOrder(bytes32 _orderHash, uint _TokenAmount) public returns(bool _success){
        //must call allowance beforehand
        int _amount; uint _price; address _maker;
        (_amount,_price,_maker) = getInfo(_orderHash);
        uint8 _v;bytes32[2] memory sig;uint salt;
        (_v,sig[0],sig[1],salt) = getSignature(_orderHash);
        address[5] memory orderAddresses;
        uint[6] memory orderValues;
        uint value;
        if(_amount > 0){
            value = uint(_amount);
            assert(value >= _TokenAmount);
            orderAddresses = [_maker,address(this),wrapped_ether_address,token_address,owner];
            orderValues = [safeMul(_TokenAmount,_price),_TokenAmount,0,0,2**256 - 1,salt];
            assert(ERC20Token.allowance(msg.sender,tokentransferproxy_address) >= _TokenAmount);
        }
        else {
            value = safeMul(uint(-_amount),_price);
            assert(value >= _TokenAmount);
            assert(Wrapped_Ether.allowance(msg.sender,tokentransferproxy_address) >= _TokenAmount);
            orderAddresses = [_maker,address(this),token_address,wrapped_ether_address,owner];
            orderValues = [_TokenAmount,safeMul(_TokenAmount,_price),0,0,2**256 - 1,salt];
        }
     uint _taken = zeroX.fillOrder(orderAddresses,orderValues,_TokenAmount,false,_v,sig[0],sig[1]);

     if(_taken > 0){
        if(_amount > 0){
            Wrapped_Ether.transfer(msg.sender,_taken);
         }
         else{
            ERC20Token.transfer(msg.sender,_taken);
         }
        if(_taken == value){
            removeOrder(_orderHash);
        }
        else{
            order_details[_orderHash].amount = order_details[_orderHash].amount - int(_TokenAmount);
        }
        FilledOrder(_orderHash,_TokenAmount,_price);
        return true;
     }
     else{
        removeOrder(_orderHash);
        return false ;
     }
    }

    function getInfo(bytes32 _hash)constant public returns(int _amount, uint _price, address _maker){
        return(order_details[_hash].amount,order_details[_hash].price,order_details[_hash].maker);
    }

    function getHashfromIndex(uint _index)constant public returns(bytes32){
        return orders[_index];
    }

    function getOrderLength()constant public returns(uint _len){
        return orders.length;
    }

    function getSignature(bytes32 _hash) constant internal returns(uint8 _v,bytes32 _r, bytes32 _s,uint salt){
        return(order_details[_hash].v,order_details[_hash].r,order_details[_hash].s,order_details[_hash].salt);
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

    function setTTP_address(address _ttp) public onlyOwner(){
        tokentransferproxy_address = _ttp;
    }


    function setOwner(address _newOwner) public onlyOwner(){
        owner = _newOwner;
    }


    function removeOrder(bytes32 _remove) internal {
    uint last_index = orders.length - 1;
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