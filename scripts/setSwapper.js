main()

async function main(){
    const [owner] = await ethers.getSigners();

    const loopingHelper = await ethers.getContractAt("Looping", '0x2f5F23ED499ABcDef7116f75e3365C553D2b4913');
    await loopingHelper.setSwapper('0x6A6E046f1353a6ad2Bc56A1F892C2CaDce650ebD', 'true')
}