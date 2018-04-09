using System.Threading.Tasks;
using Microsoft.CodeAnalysis;
using MirrorSharp.Testing;
using Xunit;
using SharpLab.Server.Common;
using SharpLab.Tests.Internal;

namespace SharpLab.Tests {
    public class ExplanationTests {
        [Theory]
        // space at the end is expected -- currently extra spaces are trimmed by JS
        [InlineData("expression-bodied member", "class C { int P => 1; }", "int P => 1; ")]
        [InlineData("pattern matching", "class C { void M() { switch(1) { case int i: break; } } }", "case int i")]
        public async Task SlowUpdate_ExplainsCSharpFeature(string name, string providedCode, string expectedCode) {
            var driver = await NewTestDriverAsync();
            driver.SetText(providedCode);

            var result = await driver.SendSlowUpdateAsync<ExplanationData[]>();

            var explanation = Assert.Single(result.ExtensionResult);
            Assert.Equal(expectedCode, explanation.Code);
            Assert.Equal(name, explanation.Name);
            Assert.NotEmpty(explanation.Text);
            Assert.StartsWith("https://docs.microsoft.com", explanation.Link);
        }

        private static async Task<MirrorSharpTestDriver> NewTestDriverAsync() {
            var driver = MirrorSharpTestDriver.New(TestEnvironment.MirrorSharpOptions);
            await driver.SendSetOptionsAsync(LanguageNames.CSharp, TargetNames.Explain);
            return driver;
        }

        private class ExplanationData {
            public string Code { get; set; }
            public string Name { get; set; }
            public string Text { get; set; }
            public string Link { get; set; }
        }
    }
}
