import { Page } from "@playwright/test";

export default class PlaywrightWrapper {

    constructor(private page: Page) { }

    async goto(url: string) {
        await this.page.goto(url, { waitUntil: "domcontentloaded" });
    }

    async waitAndClick(locator: string) {
        const element = this.page.locator(locator);
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        await element.click();
    }

async waitAndClickWithChallenge(locator1: string, locator2: string, option: string) {
    const frame = await this.page.locator(locator1).contentFrame();
    const element = frame.locator(locator2);

    await element.waitFor({ state: "visible" });
    await element.scrollIntoViewIfNeeded();
    await element.selectOption(option);
}


    async waitAndClickGetByText(text: string) {
        const element = this.page.getByText(text);
        await element.waitFor({ state: "visible" });
        await element.click();
    }

    async waitAndClickGetByRole(roleType: string, role: string) {
        const element = this.page.getByRole(roleType as any, { name: role });
        await element.waitFor({ state: "visible" });
        await element.click();
        return await element.textContent();
    }

    async waitAndClickGetByRoleBasic(roleType: string) {
        const element = this.page.getByRole(roleType as any);
        await element.waitFor({ state: "visible" });
        await element.click();
    }

    async waitAndClickGetByRoleWithChallenge(locator1: string, roleType: string, role: string) {
        const frame = this.page.locator(locator1).contentFrame();
        const element = frame.getByRole(roleType as any, { name: role });
        
        await element.waitFor({ state: "visible" });
        await element.click();
    }

    async waitAndClickGetByRoleWithoutReturn(roleType: string, role: string) {
        const element = this.page.getByRole(roleType as any, { name: role });
        await element.waitFor({ state: "visible" });
        await element.click();
    }

    async waitForPopupAndClickGetByRole(roleType: string, role: string) {
        const [newPage] = await Promise.all([
            this.page.waitForEvent('popup'),
            this.waitAndClickGetByRole(roleType, role)
        ])
        await newPage.waitForLoadState();

        return newPage;
    }

    async navigateTo(link: string) {
        await Promise.all([
            this.page.click(link)
        ])
    }

    async waitGetByRoleLink(roleType: string, role: string) {
        const element = this.page.getByRole(roleType as any, { name: role });
        await element.waitFor({ state: "visible" });
        return this.page;
    }

    async fill(locator: string, text: string){
        const element = this.page.locator(locator);
        await element.waitFor({ state: "visible" });
        await element.fill(text);
    }

    async fillByLabel(label: string, text: string){
        const element = this.page.getByLabel(label);
        await element.waitFor({ state: "visible" });
        await element.fill(text);
    }

    async fillByTestId(testId: string, text: string){
        const element = this.page.getByTestId(testId)
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        await element.fill(text);
    }

    async clickByLabel(label: string){
        const element = this.page.getByLabel(label);
        await element.waitFor({
            state: "visible"
        });
        await element.click();
    }

    async clickByTestId(testId: string){
        const element = this.page.getByTestId(testId).first();
        await element.waitFor({
            state: "visible"
        });
        await element.click();
    }

    async clickByLabelExact(label: string, exact: boolean){
        const element = this.page.getByLabel(label, { exact: exact.toString() === "true" });
        await element.waitFor({ state: "visible" });
        await element.click();
    }

    async getByTextExact(text: string, exact: boolean){
        const element = this.page.getByText(text, { exact: exact.toString() === "true" }).first();
        await element.waitFor({ state: "visible" });
        await element.click();
        return element.textContent();
    }

    async getTextByLocator(locator: string){
        const element = this.page.locator(locator);
        await element.waitFor({ state: "attached" });
        return await element.textContent();
    }

    async getByText(text: string){
        const element = this.page.getByText(text).first();
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        return (await element.textContent()).trim();
    }

    async getByTestId(testId: string){
        const element = this.page.getByTestId(testId).first();
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        return (await element.textContent()).trim();
    }

    async isEnableByTestID(testId: string): Promise<boolean>{
        const element = this.page.getByTestId(testId).first();
        await element.waitFor({ state: 'visible' });
        await element.scrollIntoViewIfNeeded();
        return await element.isEnabled();
    } 
    
    async isDisableByTestID(testId: string): Promise<boolean>{
        const element = this.page.getByTestId(testId).first();
        await element.waitFor({ state: 'visible' });
        await element.scrollIntoViewIfNeeded();
        return await element.isDisabled();
    }

    async getInputValueByTestId(testId: string){
        const element = this.page.getByTestId(testId);
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        return (await element.inputValue()).trim();
    }


    async getByTextOnPosition(text: string, position: number){
        const element = this.page.getByText(text).nth(position - 1);
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        return (await element.textContent()).trim();
    }

    async getByTextWithScrollToElement(text: string){
        const element = this.page.getByText(text, { exact: true }).first();
        await element.waitFor({ state: "visible" });
        await element.scrollIntoViewIfNeeded();
        return (await element.textContent()).trim();
    }

    async getByTextCustom(text: string){
        const element = this.page.getByText(text);
        await element.waitFor({ state: "visible" });
        return (await element.textContent()).trim();
    }

    async waitForGridLoad(locator: string){
        const element = this.page.locator(locator).first();
        await element.waitFor({ state: "attached" });
    }

    async waitForPopup(){
        return await this.page.waitForEvent('popup');
    }

    async waitForGridCellLoad(name: string){
        const element = this.page.locator(`role=gridcell[name="${name}"]`);
        await element.waitFor({ state: "visible" });
        return await element.innerText()
    }

    async getTextByRole(roleType: string, role: string) {
        const element = this.page.getByRole(roleType as any, { name: role }).first();
        await element.waitFor({ state: "visible" });
        return (await element.textContent()).trim();
    }

    async close(){
        return await this.page.close();
    }

}