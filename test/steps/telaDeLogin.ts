import { Given, When, Then } from "@cucumber/cucumber";
import { fixture } from "../../hooks/pageFixture";
import LoginPage from "../../pages/loginPage";
import Assert from "../../helper/wrapper/assert";
import { timeout } from "../../config/globalConfig";

let loginPage: LoginPage;
let assert: Assert;

Given('the user is on the login page', { timeout: timeout }, async function () {
  loginPage = new LoginPage(fixture.page);
  assert = new Assert(fixture.page);
  await loginPage.goto(process.env.BASEURL);
  await loginPage.getSwagLabsText();
});

When('the user enters the correct username', { timeout: timeout }, async function () {
  await loginPage.fillUserName(process.env.USER_NAME);
});

When('the user enters the incorrect username', { timeout: timeout }, async function () {
  await loginPage.fillUserName("incorrect-username");
});

When('the user enters the correct password', { timeout: timeout }, async function () {
  await loginPage.fillPassword(process.env.PASSWORD);
});

When('the user enters the incorrect password', { timeout: timeout }, async function () {
  await loginPage.fillPassword("incorrect-password");
});

When('the user clicks the login button', { timeout: timeout }, async function () {
  await loginPage.waitAndClickLoginButton();
});

Then('the home page is displayed', { timeout: timeout }, async function () {
  const titleText = await loginPage.getProductsText();
  assert.assertElementContains(titleText, "Products");
});

Then('an error message is displayed', { timeout: timeout }, async function () {
  const errorMessage = await loginPage.getErrorMessageText();
  assert.assertElementContains(
    errorMessage,
    "Username and password do not match any user in this service"
  );
});